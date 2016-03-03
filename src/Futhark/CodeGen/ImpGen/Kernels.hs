{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeFamilies, LambdaCase #-}
module Futhark.CodeGen.ImpGen.Kernels
  ( compileProg
  )
  where

import Control.Monad.Except
import Control.Monad.Reader
import Control.Applicative
import Data.Maybe
import Data.Monoid
import qualified Data.HashMap.Lazy as HM
import qualified Data.HashSet as HS
import Data.List

import Prelude

import Futhark.MonadFreshNames
import Futhark.Transform.Rename
import Futhark.Representation.ExplicitMemory
import qualified Futhark.CodeGen.ImpCode.Kernels as Imp
import Futhark.CodeGen.ImpCode.Kernels (bytes)
import qualified Futhark.CodeGen.ImpGen as ImpGen
import qualified Futhark.Analysis.ScalExp as SE
import qualified Futhark.Representation.ExplicitMemory.IndexFunction.Unsafe as IxFun
import Futhark.CodeGen.SetDefaultSpace
import Futhark.Tools (partitionChunkedLambdaParameters)
import Futhark.Util.IntegralExp (quotRoundingUp)

type CallKernelGen = ImpGen.ImpM Imp.HostOp
type InKernelGen = ImpGen.ImpM Imp.KernelOp

callKernelOperations :: ImpGen.Operations Imp.HostOp
callKernelOperations =
  ImpGen.Operations { ImpGen.opsExpCompiler = expCompiler
                    , ImpGen.opsCopyCompiler = callKernelCopy
                    , ImpGen.opsOpCompiler = opCompiler
                    }


inKernelOperations :: ImpGen.Operations Imp.KernelOp
inKernelOperations = (ImpGen.defaultOperations cannotAllocInKernel)
                     { ImpGen.opsCopyCompiler = inKernelCopy
                     , ImpGen.opsExpCompiler = inKernelExpCompiler
                     }

compileProg :: MonadFreshNames m => Prog -> m (Either String Imp.Program)
compileProg prog =
  fmap (setDefaultSpace (Imp.Space "device")) <$>
  ImpGen.compileProg callKernelOperations (Imp.Space "device") prog

opCompiler :: ImpGen.Destination -> Op ExplicitMemory
              -> ImpGen.ImpM Imp.HostOp ()
opCompiler dest (Alloc e space) =
  ImpGen.compileAlloc dest e space
opCompiler dest (Inner kernel) =
  kernelCompiler dest kernel

cannotAllocInKernel :: ImpGen.Destination -> Op ExplicitMemory
                    -> ImpGen.ImpM Imp.KernelOp ()
cannotAllocInKernel _ _ =
  throwError "Cannot allocate memory in kernel."

-- | Recognise kernels (maps), give everything else back.
kernelCompiler :: ImpGen.Destination -> Kernel ExplicitMemory
               -> ImpGen.ImpM Imp.HostOp ()

kernelCompiler dest NumGroups = do
  [v] <- ImpGen.funcallTargets dest
  ImpGen.emit $ Imp.Op $ Imp.GetNumGroups v

kernelCompiler dest GroupSize = do
  [v] <- ImpGen.funcallTargets dest
  ImpGen.emit $ Imp.Op $ Imp.GetGroupSize v

kernelCompiler
  (ImpGen.Destination dest)
  (MapKernel _ _ global_thread_index ispace inps returns body) = do

  let kernel_size = product $ map (ImpGen.compileSubExp . snd) ispace

      global_thread_index_param = Imp.ScalarParam global_thread_index int32
      shape = map (ImpGen.compileSubExp . snd) ispace
      indices = map fst ispace

      indices_lparams = [ Param index (Scalar int32) | index <- indices ]
      bound_in_kernel = global_thread_index : indices ++ map kernelInputName inps
      kernel_bnds = bodyBindings body

      index_expressions = unflattenIndex shape $ Imp.ScalarVar global_thread_index
      set_indices = forM_ (zip indices index_expressions) $ \(i, x) ->
        ImpGen.emit $ Imp.SetScalar i x

      read_params = mapM_ readKernelInput inps

      perms = map snd returns
      write_result =
        sequence_ $ zipWith3 (writeThreadResult indices) perms dest $ bodyResult body

  makeAllMemoryGlobal $ do
    kernel_body <- fmap (setBodySpace $ Imp.Space "global") $
                   ImpGen.subImpM_ inKernelOperations $
                   ImpGen.withParams [global_thread_index_param] $
                   ImpGen.declaringLParams (indices_lparams ++ map kernelInputParam inps) $ do
                     ImpGen.comment "compute thread index" set_indices
                     ImpGen.comment "read kernel parameters" read_params
                     ImpGen.compileBindings kernel_bnds $
                      ImpGen.comment "write kernel result" write_result

    group_size <- newVName "group_size"
    num_groups <- newVName "num_groups"
    let group_size_var = Imp.ScalarVar group_size
    ImpGen.emit $ Imp.DeclareScalar group_size int32
    ImpGen.emit $ Imp.DeclareScalar num_groups int32
    ImpGen.emit $ Imp.Op $ Imp.GetGroupSize group_size
    ImpGen.emit $ Imp.SetScalar num_groups $
      kernel_size `quotRoundingUp` group_size_var

    -- Compute the variables that we need to pass to and from the
    -- kernel.
    uses <- computeKernelUses dest (kernel_size, kernel_body) bound_in_kernel

    ImpGen.emit $ Imp.Op $ Imp.CallKernel $ Imp.Map Imp.MapKernel {
        Imp.mapKernelThreadNum = global_thread_index
      , Imp.mapKernelBody = kernel_body
      , Imp.mapKernelUses = uses
      , Imp.mapKernelSize = kernel_size
      , Imp.mapKernelNumGroups = Imp.VarSize num_groups
      , Imp.mapKernelGroupSize = Imp.VarSize group_size
      }

kernelCompiler
  (ImpGen.Destination dest)
  (ChunkedMapKernel _ _ kernel_size o lam _) = do
    local_id <- newVName "local_id"
    group_id <- newVName "group_id"

    (num_groups, group_size, per_thread_chunk, num_elements, _, num_threads) <-
      compileKernelSize kernel_size

    let num_nonconcat = chunkedKernelNonconcatOutputs lam
        (nonconcat_targets, concat_targets) = splitAt num_nonconcat dest
        (arr_chunk_param, _) =
          partitionChunkedLambdaParameters $ lambdaParams lam

    (call_with_prologue, prologue) <-
      makeAllMemoryGlobal $ ImpGen.subImpM inKernelOperations $
      ImpGen.withPrimVar local_id int32 $
      ImpGen.declaringPrimVar local_id int32 $
      ImpGen.declaringPrimVar group_id int32 $
      ImpGen.declaringPrimVar (lambdaIndex lam) int32 $
      ImpGen.declaringLParams (lambdaParams lam) $ do

        ImpGen.emit $
          Imp.Op (Imp.GetLocalId local_id 0) <>
          Imp.Op (Imp.GetGroupId group_id 0) <>
          Imp.Op (Imp.GetGlobalId (lambdaIndex lam) 0)

        let indexNonconcatTarget (Prim t) (ImpGen.ArrayDestination
                                           (ImpGen.CopyIntoMemory dest_loc) [_]) = do
              (mem, space, offset) <-
                ImpGen.fullyIndexArray' dest_loc [ImpGen.varIndex (lambdaIndex lam)] t
              return $ ImpGen.ArrayElemDestination mem t space offset
            indexNonconcatTarget _ (ImpGen.ArrayDestination
                                    (ImpGen.CopyIntoMemory dest_loc) (_:dest_dims)) = do
              let dest_loc' = ImpGen.sliceArray dest_loc
                              [ImpGen.varIndex (lambdaIndex lam)]
              return $ ImpGen.ArrayDestination (ImpGen.CopyIntoMemory dest_loc') dest_dims
            indexNonconcatTarget _ _ =
              throwError "indexNonconcatTarget: invalid target."
            indexConcatTarget (ImpGen.ArrayDestination
                               (ImpGen.CopyIntoMemory dest_loc) (_:dest_dims)) = do
              let dest_loc' = ImpGen.offsetArray dest_loc $
                              ImpGen.sizeToScalExp per_thread_chunk *
                              ImpGen.varIndex (lambdaIndex lam)
              return $ ImpGen.ArrayDestination (ImpGen.CopyIntoMemory dest_loc') $
                Nothing : dest_dims
            indexConcatTarget _ =
              throwError "indexConcatTarget: invalid target."
        nonconcat_elem_targets <-
          zipWithM indexNonconcatTarget (lambdaReturnType lam) nonconcat_targets
        concat_elem_targets <- mapM indexConcatTarget concat_targets

        let map_dest =
              ImpGen.Destination $ nonconcat_elem_targets <> concat_elem_targets

        map_op <-
          ImpGen.subImpM_ inKernelOperations $ do
            computeThreadChunkSize
              comm
              (Imp.ScalarVar $ lambdaIndex lam)
              (Imp.innerExp $ Imp.dimSizeToExp num_threads)
              (ImpGen.dimSizeToExp per_thread_chunk)
              (ImpGen.dimSizeToExp num_elements) $
              paramName arr_chunk_param
            ImpGen.compileBody map_dest $ lambdaBody lam

        let bound_in_kernel = map paramName (lambdaParams lam) ++
                              [lambdaIndex lam,
                               local_id,
                               group_id]

        return $ \prologue -> do
          let body = mconcat [prologue, map_op]

          uses <- computeKernelUses dest (freeIn body) bound_in_kernel

          ImpGen.emit $ Imp.Op $ Imp.CallKernel $ Imp.AnyKernel Imp.Kernel
            { Imp.kernelBody = body
            , Imp.kernelLocalMemory = mempty
            , Imp.kernelUses = uses
            , Imp.kernelNumGroups = num_groups
            , Imp.kernelGroupSize = group_size
            , Imp.kernelName = lambdaIndex lam
            }
    call_with_prologue prologue
    where comm = case o of Disorder -> Commutative
                           InOrder -> Noncommutative

kernelCompiler
  (ImpGen.Destination dest)
  (ReduceKernel _ _ kernel_size comm reduce_lam fold_lam nes _) = do

    local_id <- newVName "local_id"
    group_id <- newVName "group_id"
    wave_size <- newVName "wave_size"
    skip_waves <- newVName "skip_waves"

    (num_groups, group_size, per_thread_chunk, num_elements, _, num_threads) <-
      compileKernelSize kernel_size

    let fold_lparams = lambdaParams fold_lam
        (reduce_targets, arr_targets) = splitAt (length nes) dest
        (fold_chunk_param, _) =
          partitionChunkedLambdaParameters $ lambdaParams fold_lam

        reduce_lparams = lambdaParams reduce_lam
        (other_index_param, actual_reduce_params) =
          partitionChunkedLambdaParameters $ lambdaParams reduce_lam
        (reduce_acc_params, reduce_arr_params) =
          splitAt (length nes) actual_reduce_params

        offset = paramName other_index_param

    (acc_mem_params, acc_local_mem) <-
      unzip <$> mapM (createAccMem group_size) reduce_acc_params

    (call_with_prologue, prologue) <-
      makeAllMemoryGlobal $ ImpGen.subImpM inKernelOperations $
      ImpGen.withPrimVar local_id int32 $
      ImpGen.declaringPrimVar local_id int32 $
      ImpGen.declaringPrimVar group_id int32 $
      ImpGen.declaringPrimVar wave_size int32 $
      ImpGen.declaringPrimVar skip_waves int32 $
      ImpGen.declaringPrimVar (lambdaIndex reduce_lam) int32 $
      ImpGen.declaringPrimVar (lambdaIndex fold_lam) int32 $
      ImpGen.withParams acc_mem_params $
      ImpGen.declaringLParams (fold_lparams++reduce_lparams) $ do

        ImpGen.emit $
          Imp.Op (Imp.GetLocalId local_id 0) <>
          Imp.Op (Imp.GetGroupId group_id 0) <>
          Imp.Op (Imp.GetGlobalId (lambdaIndex reduce_lam) 0) <>
          Imp.Op (Imp.GetGlobalId (lambdaIndex fold_lam) 0) <>
          Imp.Op (Imp.GetWaveSize wave_size)

        ImpGen.Destination reduce_acc_targets <-
          ImpGen.destinationFromParams reduce_acc_params

        let indexArrayTarget (ImpGen.ArrayDestination
                              (ImpGen.CopyIntoMemory dest_loc) (_:dest_dims)) = do
              let dest_loc' = ImpGen.offsetArray dest_loc $
                              ImpGen.sizeToScalExp per_thread_chunk *
                              ImpGen.varIndex (lambdaIndex fold_lam)
              return $ ImpGen.ArrayDestination (ImpGen.CopyIntoMemory dest_loc') $
                Nothing : dest_dims
            indexArrayTarget _ =
              throwError "indexArrayTarget: invalid target for map-out."
        arr_chunk_targets <- mapM indexArrayTarget arr_targets

        let fold_dest =
              ImpGen.Destination $ reduce_acc_targets <> arr_chunk_targets

        fold_op <-
          ImpGen.subImpM_ inKernelOperations $ do
            computeThreadChunkSize
              comm
              (Imp.ScalarVar $ lambdaIndex fold_lam)
              (Imp.innerExp $ Imp.dimSizeToExp num_threads)
              (ImpGen.dimSizeToExp per_thread_chunk)
              (ImpGen.dimSizeToExp num_elements) $
              paramName fold_chunk_param
            ImpGen.compileBody fold_dest $ lambdaBody fold_lam

        write_fold_result <-
          ImpGen.subImpM_ inKernelOperations $
          zipWithM_ (writeParamToLocalMemory $ Imp.ScalarVar local_id)
          acc_local_mem reduce_acc_params

        let read_reduce_args = zipWithM_ (readReduceArgument local_id offset)
                               reduce_arr_params acc_local_mem
            reduce_acc_dest = ImpGen.Destination reduce_acc_targets

        reduce_op <-
          ImpGen.subImpM_ inKernelOperations $ do
            ImpGen.comment "read array element" read_reduce_args
            ImpGen.compileBody reduce_acc_dest $ lambdaBody reduce_lam

        write_result <-
          ImpGen.subImpM_ inKernelOperations $
          zipWithM_ (writeFinalResult [group_id]) reduce_targets reduce_acc_params

        let bound_in_kernel = map paramName (lambdaParams fold_lam ++
                                             lambdaParams reduce_lam) ++
                              [lambdaIndex fold_lam,
                               lambdaIndex reduce_lam,
                               offset,
                               local_id,
                               group_id] ++
                              map Imp.paramName acc_mem_params

        return $ \prologue -> do
          -- wave_id, in_wave_id and num_waves will all be inlined
          -- whereever they are used.  This leads to ugly code, but
          -- declaring them as variables (and setting them) early in
          -- the kernel dramatically reduces performance on NVIDIAs
          -- OpenCL implementation.  I suspect it prevents unrolling
          -- of the in-wave reduction loop.  It is possible that we
          -- may be able to declare these as variables just preceding
          -- the loops where they are used, without losing
          -- performance.  This can be done when we become tired of
          -- looking at ugly kernel code.
          let wave_id = Imp.BinOp (SQuot Int32)
                        (Imp.ScalarVar local_id)
                        (Imp.ScalarVar wave_size)
              in_wave_id = Imp.ScalarVar local_id -
                           (wave_id * Imp.ScalarVar wave_size)
              num_waves = Imp.BinOp (SQuot Int32)
                          (Imp.innerExp (Imp.dimSizeToExp group_size) +
                           Imp.ScalarVar wave_size - 1)
                          (Imp.ScalarVar wave_size)

              doing_in_wave_reductions =
                Imp.CmpOp (CmpSlt Int32) (Imp.ScalarVar offset) $ Imp.ScalarVar wave_size
              apply_in_in_wave_iteration =
                Imp.CmpOp (CmpEq int32)
                (Imp.BinOp (And Int32) in_wave_id (2 * Imp.ScalarVar offset - 1)) 0
              in_wave_reductions =
                Imp.SetScalar offset 1 <>
                Imp.While doing_in_wave_reductions
                  (Imp.If apply_in_in_wave_iteration
                   (reduce_op <> write_fold_result) mempty <>
                   Imp.SetScalar offset (Imp.ScalarVar offset * 2))

              doing_cross_wave_reductions =
                Imp.CmpOp (CmpSlt Int32) (Imp.ScalarVar skip_waves) num_waves
              is_first_thread_in_wave =
                Imp.CmpOp (CmpEq int32) in_wave_id 0
              wave_not_skipped =
                Imp.CmpOp (CmpEq int32)
                (Imp.BinOp (And Int32) wave_id (2 * Imp.ScalarVar skip_waves - 1))
                0
              apply_in_cross_wave_iteration =
                Imp.BinOp LogAnd is_first_thread_in_wave wave_not_skipped
              cross_wave_reductions =
                Imp.SetScalar skip_waves 1 <>
                Imp.While doing_cross_wave_reductions
                  (Imp.Op Imp.Barrier <>
                   Imp.SetScalar offset (Imp.ScalarVar skip_waves *
                                         Imp.ScalarVar wave_size) <>
                   Imp.If apply_in_cross_wave_iteration
                   (reduce_op <> write_fold_result) mempty <>
                   Imp.SetScalar skip_waves (Imp.ScalarVar skip_waves * 2))

              write_group_result =
                Imp.If (Imp.CmpOp (CmpEq int32) (Imp.ScalarVar local_id) 0)
                write_result mempty

              body = mconcat [prologue,
                              fold_op,
                              write_fold_result,
                              in_wave_reductions,
                              cross_wave_reductions,
                              write_group_result]

              local_mem = map (ensureAlignment $ alignmentMap body) acc_local_mem

          uses <- computeKernelUses dest (freeIn body) bound_in_kernel

          ImpGen.emit $ Imp.Op $ Imp.CallKernel $ Imp.AnyKernel Imp.Kernel
            { Imp.kernelBody = body
            , Imp.kernelLocalMemory = local_mem
            , Imp.kernelUses = uses
            , Imp.kernelNumGroups = num_groups
            , Imp.kernelGroupSize = group_size
            , Imp.kernelName = lambdaIndex fold_lam
            }
    call_with_prologue prologue
  where readReduceArgument local_id offset param (mem, _)
          | Prim _ <- paramType param =
              ImpGen.emit $
                Imp.SetScalar (paramName param) $
                Imp.Index mem (bytes i) bt (Space "local")
          | otherwise =
              return ()
          where i = (Imp.ScalarVar local_id + Imp.ScalarVar offset) * Imp.SizeOf bt
                bt = elemType $ paramType param

kernelCompiler
  (ImpGen.Destination dest)
  (ScanKernel _ _ kernel_size order lam input) = do
    let (nes, arrs) = unzip input
        (arrs_dest, partials_dest) = splitAt (length input) dest
    local_id <- newVName "local_id"
    group_id <- newVName "group_id"
    wave_size <- newVName "wave_size"
    global_id <- newVName "global_id"
    thread_chunk_size <- newVName "thread_chunk_size"

    renamed_lam <- renameLambda lam

    (num_groups, local_size, elements_per_thread,
     num_elements, _offset_multiple, num_threads) <-
      compileKernelSize kernel_size

    let (other_index_param, actual_params) =
          partitionChunkedLambdaParameters $ lambdaParams lam
        (x_params, y_params) =
          splitAt (length nes) actual_params

    (acc_mem_params, acc_local_mem) <-
      unzip <$> mapM (createAccMem local_size) x_params

    let twoDimInput (ImpGen.ArrayEntry (ImpGen.MemLocation mem shape ixfun) bt) =
          let shape' = [num_threads, elements_per_thread] ++ drop 1 shape
              ixfun' = IxFun.reshape ixfun $
                       [DimNew $ kernelNumThreads kernel_size,
                        DimNew $ kernelElementsPerThread kernel_size] ++
                       map (DimNew . ImpGen.dimSizeToSubExp) (drop 1 shape)
          in ImpGen.ArrayEntry (ImpGen.MemLocation mem shape' ixfun') bt

    (call_with_body, body) <-
      makeAllMemoryGlobal $ ImpGen.subImpM inKernelOperations $
      ImpGen.declaringPrimVar local_id int32 $
      ImpGen.declaringPrimVar group_id int32 $
      ImpGen.declaringPrimVar wave_size int32 $
      ImpGen.declaringPrimVar thread_chunk_size int32 $
      ImpGen.declaringPrimVar (lambdaIndex lam) int32 $
      ImpGen.declaringPrimVar (lambdaIndex renamed_lam) int32 $
      ImpGen.declaringPrimVar global_id int32 $
      ImpGen.withParams acc_mem_params $
      ImpGen.declaringLParams (lambdaParams lam) $
      ImpGen.declaringLParams (lambdaParams renamed_lam) $
      ImpGen.modifyingArrays arrs twoDimInput $ do

        ImpGen.emit $
          Imp.Op (Imp.GetLocalId local_id 0) <>
          Imp.Op (Imp.GetGroupId group_id 0) <>
          Imp.Op (Imp.GetGlobalId global_id 0) <>
          Imp.Op (Imp.GetWaveSize wave_size)

        -- 'lambdaIndex lam' is the offset of the element that the
        -- current thread is responsible for.  Since a single
        -- workgroup processes more elements than it has threads, this
        -- will change over time.
        ImpGen.emit $
          Imp.SetScalar (lambdaIndex lam) $
          Imp.ScalarVar global_id *
          Imp.innerExp (Imp.dimSizeToExp elements_per_thread)

        x_dest <- ImpGen.destinationFromParams x_params
        y_dest <- ImpGen.destinationFromParams y_params

        -- The number of elements processed by the thread so far.
        elements_scanned <- newVName "elements_scanned"

        let readScanElement param inp_arr =
              ImpGen.copyDWIM (paramName param) []
              (Var inp_arr) [ImpGen.varIndex global_id,
                             ImpGen.varIndex elements_scanned]

        computeThreadChunkSize
          Noncommutative
          (Imp.ScalarVar global_id)
          (Imp.innerExp $ Imp.dimSizeToExp num_threads)
          (ImpGen.dimSizeToExp elements_per_thread)
          (ImpGen.dimSizeToExp num_elements)
          thread_chunk_size

        zipWithM_ ImpGen.compileSubExpTo
          (ImpGen.valueDestinations x_dest) nes

        read_params <-
          ImpGen.collect $ zipWithM_ readScanElement y_params arrs

        let (indices, explode_n, explode_m) = case order of
              ScanTransposed -> ([elements_scanned, global_id],
                                 kernelElementsPerThread kernel_size,
                                 kernelNumThreads kernel_size)
              ScanFlat       ->  ([global_id, elements_scanned],
                                  kernelNumThreads kernel_size,
                                  kernelElementsPerThread kernel_size)

            writeScanElement (ImpGen.ArrayDestination
                              (ImpGen.CopyIntoMemory (ImpGen.MemLocation mem dims ixfun))
                              setdims) =
              writeFinalResult indices $
              ImpGen.ArrayDestination
              (ImpGen.CopyIntoMemory (ImpGen.MemLocation mem dims ixfun'))
              setdims
              where ixfun' = explodeOuterDimension
                             (Shape $ map sizeToSubExp dims)
                             explode_n explode_m ixfun
            writeScanElement _ =
              const $ fail "writeScanElement: invalid destination"

            sizeToSubExp (Imp.ConstSize k) = constant k
            sizeToSubExp (Imp.VarSize v)   = Var v

        write_arrs <-
          ImpGen.collect $ zipWithM_ writeScanElement arrs_dest x_params

        op_to_x <- ImpGen.collect $ ImpGen.compileBody x_dest $ lambdaBody lam
        ImpGen.emit $
          Imp.Comment "sequentially scan a chunk" $
          Imp.For elements_scanned (Imp.ScalarVar thread_chunk_size) $
            read_params <>
            op_to_x <>
            write_arrs <>
            Imp.SetScalar (lambdaIndex lam)
            (Imp.BinOp (Add Int32) (Imp.ScalarVar $ lambdaIndex lam) 1)

        zipWithM_ (writeParamToLocalMemory $ Imp.ScalarVar local_id)
          acc_local_mem x_params

        let wave_id = Imp.BinOp (SQuot Int32)
                      (Imp.ScalarVar local_id)
                      (Imp.ScalarVar wave_size)
            in_wave_id = Imp.ScalarVar local_id -
                         (wave_id * Imp.ScalarVar wave_size)
            inWaveScan' = inWaveScan (Imp.ScalarVar wave_size) local_id acc_local_mem

        inWaveScan' lam
        ImpGen.emit $ Imp.Op Imp.Barrier

        pack_wave_results <-
          ImpGen.collect $
          zipWithM_ (writeParamToLocalMemory wave_id) acc_local_mem y_params

        let last_in_wave =
              Imp.CmpOp (CmpEq int32) in_wave_id $ Imp.ScalarVar wave_size - 1
        ImpGen.emit $
          Imp.Comment "last thread of wave 'i' writes its result to offset 'i'" $
          Imp.If last_in_wave pack_wave_results mempty

        ImpGen.emit $ Imp.Op Imp.Barrier

        let is_first_wave = Imp.CmpOp (CmpEq int32) wave_id 0
        scan_first_wave <- ImpGen.collect $ inWaveScan' renamed_lam
        ImpGen.emit $
          Imp.Comment "scan the first wave, after which offset 'i' contains carry-in for warp 'i+1'" $
          Imp.If is_first_wave scan_first_wave mempty

        ImpGen.emit $ Imp.Op Imp.Barrier

        read_carry_in <-
          ImpGen.collect $
          zipWithM_ (readParamFromLocalMemory
                     (paramName other_index_param) (wave_id - 1))
          x_params acc_local_mem

        op_to_y <- ImpGen.collect $ ImpGen.compileBody y_dest $ lambdaBody lam
        ImpGen.emit $
          Imp.Comment "carry-in for every wave except the first" $
          Imp.If is_first_wave mempty $
          Imp.Comment "read operands" read_carry_in <>
          Imp.Comment "perform operation" op_to_y

        zipWithM_ (writeFinalResult [group_id, local_id]) partials_dest y_params

        return $ \body -> do

          let local_mem = map (ensureAlignment $ alignmentMap body) acc_local_mem
              bound_in_kernel = HM.keys (scopeOf lam) ++
                                HM.keys (scopeOf renamed_lam) ++
                                [local_id,
                                 group_id,
                                 global_id] ++
                                map Imp.paramName acc_mem_params

          uses <- computeKernelUses dest (freeIn body) bound_in_kernel

          ImpGen.emit $ Imp.Op $ Imp.CallKernel $ Imp.AnyKernel Imp.Kernel
            { Imp.kernelBody = body
            , Imp.kernelLocalMemory = local_mem
            , Imp.kernelUses = uses
            , Imp.kernelNumGroups = num_groups
            , Imp.kernelGroupSize = local_size
            , Imp.kernelName = lambdaIndex lam
            }

    call_with_body body

expCompiler :: ImpGen.ExpCompiler Imp.HostOp
-- We generate a simple kernel for itoa and replicate.
expCompiler target (PrimOp (Iota n x)) = do
  i <- newVName "i"
  v <- newVName "v"
  global_thread_index <- newVName "global_thread_index"
  let bnd = Let (Pattern [] [PatElem v BindVar $ Scalar int32]) () $
            PrimOp $ BinOp (Add Int32) (Var i) x
  kernelCompiler target $
    MapKernel [] n global_thread_index [(i,n)] [] [(Prim int32,[0])] (Body () [bnd] [Var v])
  return ImpGen.Done

expCompiler target (PrimOp (Replicate n se)) = do
  global_thread_index <- newVName "global_thread_index"
  t <- subExpType se
  let row_rank = arrayRank t
      row_dims = arrayDims t
  i <- newVName "i"
  js <- replicateM row_rank $ newVName "j"
  let indices = (i,n) : zip js row_dims
  kernelCompiler target =<<
    case se of
      Var v | row_rank > 0 -> do
        input_name <- newVName "input"
        let input = KernelInput (Param input_name $ Scalar $ elemType t)
                    v (map Var js)
        return $
          MapKernel [] n global_thread_index indices [input]
          [(t,[0..row_rank])] (Body () [] [Var input_name])
      _ ->
        return $
        MapKernel [] n global_thread_index [(i,n)] []
        [(t,[0..arrayRank t])] (Body () [] [se])
  return ImpGen.Done

-- Allocation in the "local" space is just a placeholder.
expCompiler _ (Op (Alloc _ (Space "local"))) =
  return ImpGen.Done

expCompiler _ e =
  return $ ImpGen.CompileExp e

compileKernelSize :: KernelSize
                  -> ImpGen.ImpM op (Imp.DimSize, Imp.DimSize, Imp.DimSize,
                                     Imp.DimSize, Imp.DimSize, Imp.DimSize)
compileKernelSize (KernelSize num_groups local_size per_thread_elements
                   num_elements offset_multiple num_threads) = do
  num_groups' <- ImpGen.subExpToDimSize num_groups
  local_size' <- ImpGen.subExpToDimSize local_size
  per_thread_elements' <- ImpGen.subExpToDimSize per_thread_elements
  num_elements' <- ImpGen.subExpToDimSize num_elements
  offset_multiple' <- ImpGen.subExpToDimSize offset_multiple
  num_threads' <- ImpGen.subExpToDimSize num_threads
  return (num_groups', local_size', per_thread_elements',
          num_elements', offset_multiple', num_threads')

callKernelCopy :: ImpGen.CopyCompiler Imp.HostOp
callKernelCopy bt
  destloc@(ImpGen.MemLocation destmem destshape destIxFun)
  srcloc@(ImpGen.MemLocation srcmem srcshape srcIxFun)
  n
  | Just (destoffset, srcoffset,
          num_arrays, size_x, size_y) <- isMapTransposeKernel bt destloc srcloc =
  ImpGen.emit $ Imp.Op $ Imp.CallKernel $
  Imp.MapTranspose bt
  destmem destoffset
  srcmem srcoffset
  num_arrays size_x size_y

  | bt_size <- primByteSize bt,
    Just destoffset <-
      ImpGen.scalExpToImpExp =<<
      IxFun.linearWithOffset destIxFun bt_size,
    Just srcoffset  <-
      ImpGen.scalExpToImpExp =<<
      IxFun.linearWithOffset srcIxFun bt_size = do
        let row_size = product $ map ImpGen.dimSizeToExp $ drop 1 srcshape
        srcspace <- ImpGen.entryMemSpace <$> ImpGen.lookupMemory srcmem
        destspace <- ImpGen.entryMemSpace <$> ImpGen.lookupMemory destmem
        ImpGen.emit $ Imp.Copy
          destmem (bytes destoffset) destspace
          srcmem (bytes srcoffset) srcspace $
          (n * row_size) `Imp.withElemType` bt

  | otherwise = do
  global_thread_index <- newVName "copy_global_thread_index"

  -- Note that the shape of the destination and the source are
  -- necessarily the same.
  let shape = map Imp.sizeToExp destshape
      shape_se = map ImpGen.sizeToScalExp destshape
      dest_is = unflattenIndex shape_se $ ImpGen.varIndex global_thread_index
      src_is = dest_is

  makeAllMemoryGlobal $ do
    (_, destspace, destidx) <- ImpGen.fullyIndexArray' destloc dest_is bt
    (_, srcspace, srcidx) <- ImpGen.fullyIndexArray' srcloc src_is bt

    let body = Imp.Write destmem destidx bt destspace $
               Imp.Index srcmem srcidx bt srcspace

    destmem_size <- ImpGen.entryMemSize <$> ImpGen.lookupMemory destmem
    let writes_to = [Imp.MemoryUse destmem destmem_size]

    reads_from <- readsFromSet $
                  HS.singleton srcmem <>
                  freeIn destIxFun <> freeIn srcIxFun <> freeIn destshape

    group_size <- newVName "group_size"
    num_groups <- newVName "num_groups"
    let group_size_var = Imp.ScalarVar group_size
        kernel_size = Imp.innerExp n * product (drop 1 shape)
    ImpGen.emit $ Imp.DeclareScalar group_size int32
    ImpGen.emit $ Imp.DeclareScalar num_groups int32
    ImpGen.emit $ Imp.Op $ Imp.GetGroupSize group_size
    ImpGen.emit $ Imp.SetScalar num_groups $
      kernel_size `quotRoundingUp` group_size_var

    let bound_in_kernel = [global_thread_index]
    body_uses <- computeKernelUses [] (kernel_size, body) bound_in_kernel

    ImpGen.emit $ Imp.Op $ Imp.CallKernel $ Imp.Map Imp.MapKernel {
        Imp.mapKernelThreadNum = global_thread_index
      , Imp.mapKernelNumGroups = Imp.VarSize num_groups
      , Imp.mapKernelGroupSize = Imp.VarSize group_size
      , Imp.mapKernelSize = kernel_size
      , Imp.mapKernelUses = nub $ body_uses ++ writes_to ++ reads_from
      , Imp.mapKernelBody = body
      }

-- | We have no bulk copy operation (e.g. memmove) inside kernels, so
-- turn any copy into a loop.
inKernelCopy :: ImpGen.CopyCompiler Imp.KernelOp
inKernelCopy = ImpGen.copyElementWise

inKernelExpCompiler :: ImpGen.ExpCompiler Imp.KernelOp
inKernelExpCompiler _ (PrimOp (Assert _ loc)) =
  fail $ "Cannot compile assertion at " ++ locStr loc ++ " inside parallel kernel."
inKernelExpCompiler _ e =
  return $ ImpGen.CompileExp e

computeKernelUses :: FreeIn a =>
                     [ImpGen.ValueDestination]
                  -> a -> [VName]
                  -> ImpGen.ImpM op [Imp.KernelUse]
computeKernelUses dest kernel_body bound_in_kernel = do
    -- Find the memory blocks containing the output arrays.
    let dest_mems = mapMaybe destMem dest
        destMem (ImpGen.ArrayDestination
                 (ImpGen.CopyIntoMemory
                  (ImpGen.MemLocation mem _ _)) _) =
          Just mem
        destMem _ =
          Nothing

    -- Compute the variables that we need to pass to the kernel.
    reads_from <- readsFromSet $
                  freeIn kernel_body `HS.difference`
                  HS.fromList (dest_mems <> bound_in_kernel)

    -- Compute what memory to copy out.  Must be allocated on device
    -- before kernel execution anyway.
    writes_to <- fmap catMaybes $ forM dest $ \case
      (ImpGen.ArrayDestination
       (ImpGen.CopyIntoMemory
        (ImpGen.MemLocation mem _ _)) _) -> do
        memsize <- ImpGen.entryMemSize <$> ImpGen.lookupMemory mem
        return $ Just $ Imp.MemoryUse mem memsize
      _ ->
        return Nothing
    return $ nub $ reads_from ++ writes_to

readsFromSet :: Names -> ImpGen.ImpM op [Imp.KernelUse]
readsFromSet free =
  fmap catMaybes $
  forM (HS.toList free) $ \var -> do
    t <- lookupType var
    case t of
      Array {} -> return Nothing
      Mem _ (Space "local") -> return Nothing
      Mem memsize _ -> Just <$> (Imp.MemoryUse var <$>
                                 ImpGen.subExpToDimSize memsize)
      Prim bt ->
        if bt == Cert
        then return Nothing
        else return $ Just $ Imp.ScalarUse var bt

-- | Change every memory block to be in the global address space.
-- This is fairly hacky and can be improved once the Futhark-level
-- memory representation supports address spaces.  This only affects
-- generated code - we still need to make sure that the memory is
-- actually present on the device (and declared as variables in the
-- kernel).
makeAllMemoryGlobal :: CallKernelGen a
                    -> CallKernelGen a
makeAllMemoryGlobal =
  local $ \env -> env { ImpGen.envVtable = HM.map globalMemory $ ImpGen.envVtable env
                      , ImpGen.envDefaultSpace = Imp.Space "global"
                      }
  where globalMemory (ImpGen.MemVar entry) =
          ImpGen.MemVar entry { ImpGen.entryMemSpace = Imp.Space "global" }
        globalMemory entry =
          entry

writeThreadResult :: [VName] -> [Int] -> ImpGen.ValueDestination -> SubExp
                  -> InKernelGen ()
writeThreadResult thread_idxs perm
  (ImpGen.ArrayDestination
   (ImpGen.CopyIntoMemory
    (ImpGen.MemLocation mem dims ixfun)) _) se = do
  set <- subExpType se

  let ixfun' = IxFun.permute ixfun perm
      destloc' = ImpGen.MemLocation mem (rearrangeShape perm dims) ixfun'

  space <- ImpGen.entryMemSpace <$> ImpGen.lookupMemory mem
  let is = map ImpGen.varIndex thread_idxs
  case set of
    Prim bt -> do
      (_, _, elemOffset) <-
        ImpGen.fullyIndexArray' destloc' is bt
      ImpGen.compileSubExpTo (ImpGen.ArrayElemDestination mem bt space elemOffset) se
    _ -> do
      let memloc = ImpGen.sliceArray destloc' is
      let dest = ImpGen.ArrayDestination (ImpGen.CopyIntoMemory memloc) $
                 replicate (arrayRank set) Nothing
      ImpGen.compileSubExpTo dest se
writeThreadResult _ _ _ _ =
  fail "Cannot handle kernel that does not return an array."

readKernelInput :: KernelInput ExplicitMemory
                -> InKernelGen ()
readKernelInput inp =
  when (primType t) $ do
    (srcmem, space, srcoffset) <-
      ImpGen.fullyIndexArray arr $ map SE.intSubExpToScalExp is
    ImpGen.emit $ Imp.SetScalar name $
      Imp.Index srcmem srcoffset (elemType t) space
  where arr = kernelInputArray inp
        name = kernelInputName inp
        t = kernelInputType inp
        is = kernelInputIndices inp

isMapTransposeKernel :: PrimType -> ImpGen.MemLocation -> ImpGen.MemLocation
                     -> Maybe (Imp.Exp, Imp.Exp,
                               Imp.Exp, Imp.Exp, Imp.Exp)
isMapTransposeKernel bt
  (ImpGen.MemLocation _ _ destIxFun)
  (ImpGen.MemLocation _ srcshape srcIxFun)
  | Just (dest_offset, perm) <- IxFun.rearrangeWithOffset destIxFun bt_size,
    Just src_offset <- IxFun.linearWithOffset srcIxFun bt_size,
    Just (r1, r2, _) <- isMapTranspose perm =
    isOk swap r1 r2 dest_offset src_offset
  | Just dest_offset <- IxFun.linearWithOffset destIxFun bt_size,
    Just (src_offset, perm) <- IxFun.rearrangeWithOffset srcIxFun bt_size,
    Just (r1, r2, _) <- isMapTranspose perm =
    isOk id r1 r2 dest_offset src_offset
  | otherwise =
    Nothing
  where bt_size = primByteSize bt
        swap (x,y) = (y,x)

        isOk f r1 r2 dest_offset src_offset = do
          dest_offset' <- ImpGen.scalExpToImpExp dest_offset
          src_offset' <- ImpGen.scalExpToImpExp src_offset
          let (num_arrays, size_x, size_y) = getSizes f r1 r2
          return (dest_offset', src_offset',
                  num_arrays, size_x, size_y)

        getSizes f r1 r2 =
          let (mapped, notmapped) =
                splitAt r1 $ map Imp.sizeToExp srcshape
              (pretrans, posttrans) =
                f $ splitAt r2 notmapped
          in (product mapped, product pretrans, product posttrans)

createAccMem :: Imp.DimSize
             -> LParam
             -> ImpGen.ImpM op (Imp.Param, (VName, Imp.Size))
createAccMem local_size param
  | Prim bt <- paramType param = do
      mem_shared <- newVName (baseString (paramName param) <> "_mem_local")
      total_size <- newVName "total_size"
      ImpGen.emit $
        Imp.DeclareScalar total_size int32
      ImpGen.emit $
        Imp.SetScalar total_size $
        Imp.SizeOf bt * Imp.innerExp (ImpGen.dimSizeToExp local_size)
      return (Imp.MemParam mem_shared (Imp.VarSize total_size) $ Space "local",
              (mem_shared, Imp.VarSize total_size))
  | ArrayMem _ _ _ mem _ <- paramAttr param = do
      mem_size <-
        ImpGen.entryMemSize <$> ImpGen.lookupMemory mem
      return (Imp.MemParam mem mem_size $ Space "local",
              (mem, mem_size))
  | otherwise =
      fail $ "createAccMem: cannot deal with accumulator param " ++
      pretty param

writeParamToLocalMemory :: Typed (MemBound u) =>
                           Imp.Exp -> (VName, t) -> Param (MemBound u)
                        -> ImpGen.ImpM op ()
writeParamToLocalMemory i (mem, _) param
  | Prim _ <- paramType param =
      ImpGen.emit $
      Imp.Write mem (bytes i') bt (Space "local") $
      Imp.ScalarVar (paramName param)
  | otherwise =
      return ()
  where i' = i * Imp.SizeOf bt
        bt = elemType $ paramType param

readParamFromLocalMemory :: Typed (MemBound u) =>
                            VName -> Imp.Exp -> Param (MemBound u) -> (VName, t)
                         -> ImpGen.ImpM op ()
readParamFromLocalMemory index i param (l_mem, _)
  | Prim _ <- paramType param =
      ImpGen.emit $
      Imp.SetScalar (paramName param) $
      Imp.Index l_mem (bytes i') bt (Space "local")
  | otherwise =
      ImpGen.emit $
      Imp.SetScalar index i
  where i' = i * Imp.SizeOf bt
        bt = elemType $ paramType param

writeFinalResult :: Typed (MemBound u) =>
                    [VName]
                 -> ImpGen.ValueDestination
                 -> Param (MemBound u)
                 -> ImpGen.ImpM op ()
writeFinalResult is (ImpGen.ArrayDestination memdest _) acc_param
  | ImpGen.CopyIntoMemory
    memloc@(ImpGen.MemLocation out_arr_mem out_shape ixfun) <- memdest = do
      target <-
        case arrayDims $ paramType acc_param of
        [] -> do
          (_, space, offset) <-
            ImpGen.fullyIndexArray' memloc (map ImpGen.varIndex is) bt
          return $
            ImpGen.ArrayElemDestination out_arr_mem bt space offset
        ds -> do
          let destloc = ImpGen.MemLocation out_arr_mem (drop 1 out_shape) $
                        IxFun.applyInd ixfun $ map ImpGen.varIndex is
          return $
            ImpGen.ArrayDestination (ImpGen.CopyIntoMemory destloc) $
            map (const Nothing) ds
      ImpGen.compileSubExpTo target $ Var $ paramName acc_param
  where bt = elemType $ paramType acc_param
writeFinalResult _ _ _ =
  fail "writeFinalResult: invalid destination"

computeThreadChunkSize :: Commutativity
                       -> Imp.Exp
                       -> Imp.Exp
                       -> Imp.Count Imp.Elements
                       -> Imp.Count Imp.Elements
                       -> VName
                       -> ImpGen.ImpM op ()
computeThreadChunkSize Commutative thread_index num_threads elements_per_thread num_elements chunk_var = do
  remaining_elements <- newVName "remaining_elements"
  ImpGen.emit $
    Imp.DeclareScalar remaining_elements int32
  ImpGen.emit $
    Imp.SetScalar remaining_elements $
    (Imp.innerExp num_elements - thread_index)
    `quotRoundingUp`
    num_threads
  ImpGen.emit $
    Imp.If (Imp.CmpOp (CmpSlt Int32)
            (Imp.innerExp elements_per_thread)
            (Imp.ScalarVar remaining_elements))
    (Imp.SetScalar chunk_var (Imp.innerExp elements_per_thread))
    (Imp.SetScalar chunk_var (Imp.ScalarVar remaining_elements))

computeThreadChunkSize Noncommutative thread_index _ elements_per_thread num_elements chunk_var = do
  starting_point <- newVName "starting_point"
  remaining_elements <- newVName "remaining_elements"

  ImpGen.emit $
    Imp.DeclareScalar starting_point int32
  ImpGen.emit $
    Imp.SetScalar starting_point $
    thread_index * Imp.innerExp elements_per_thread

  ImpGen.emit $
    Imp.DeclareScalar remaining_elements int32
  ImpGen.emit $
    Imp.SetScalar remaining_elements $
    Imp.innerExp num_elements - Imp.ScalarVar starting_point

  let no_remaining_elements = Imp.CmpOp (CmpSle Int32)
                              (Imp.ScalarVar remaining_elements) 0
      beyond_bounds = Imp.CmpOp (CmpSle Int32)
                      (Imp.innerExp num_elements)
                      (Imp.ScalarVar starting_point)

  ImpGen.emit $
    Imp.If (Imp.BinOp LogOr no_remaining_elements beyond_bounds)
    (Imp.SetScalar chunk_var 0)
    (Imp.If is_last_thread
     (Imp.SetScalar chunk_var $ Imp.innerExp last_thread_elements)
     (Imp.SetScalar chunk_var $ Imp.innerExp elements_per_thread))
  where last_thread_elements =
          num_elements - Imp.elements thread_index * elements_per_thread
        is_last_thread =
          Imp.CmpOp (CmpSlt Int32)
          (Imp.innerExp num_elements)
          ((thread_index + 1) * Imp.innerExp elements_per_thread)

inWaveScan :: Imp.Exp
           -> VName
           -> [(VName, t)]
           -> Lambda
           -> ImpGen.ImpM op ()
inWaveScan wave_size local_id acc_local_mem scan_lam = do
  skip_threads <- newVName "skip_threads"
  let in_wave_thread_active =
        Imp.CmpOp (CmpSle Int32) (Imp.ScalarVar skip_threads) in_wave_id
      (other_index_param, actual_params) =
        partitionChunkedLambdaParameters $ lambdaParams scan_lam
      (x_params, y_params) =
        splitAt (length actual_params `div` 2) actual_params
  read_operands <-
    ImpGen.collect $
    zipWithM_ (readParamFromLocalMemory (paramName other_index_param) $
               Imp.ScalarVar local_id -
               Imp.ScalarVar skip_threads)
    x_params acc_local_mem
  scan_y_dest <- ImpGen.destinationFromParams y_params

  -- Set initial y values
  zipWithM_ (readParamFromLocalMemory (lambdaIndex scan_lam) $ Imp.ScalarVar local_id)
    y_params acc_local_mem

  op_to_y <- ImpGen.collect $ ImpGen.compileBody scan_y_dest $ lambdaBody scan_lam
  write_operation_result <-
    ImpGen.collect $
    zipWithM_ (writeParamToLocalMemory $ Imp.ScalarVar local_id)
    acc_local_mem y_params
  ImpGen.emit $
    Imp.Comment "in-wave scan (no barriers needed)" $
    Imp.DeclareScalar skip_threads int32 <>
    Imp.SetScalar skip_threads 1 <>
    Imp.While (Imp.CmpOp (CmpSlt Int32) (Imp.ScalarVar skip_threads) wave_size)
    (Imp.If in_wave_thread_active
     (Imp.Comment "read operands" read_operands <>
      Imp.Comment "perform operation" op_to_y <>
      Imp.Comment "write result" write_operation_result)
     mempty <>
     Imp.SetScalar skip_threads (Imp.ScalarVar skip_threads * 2))
  where wave_id = Imp.BinOp (SQuot Int32) (Imp.ScalarVar local_id) wave_size
        in_wave_id = Imp.ScalarVar local_id - wave_id * wave_size

type AlignmentMap = HM.HashMap VName PrimType

lookupAlignment :: VName -> AlignmentMap -> PrimType
lookupAlignment = HM.lookupDefault smallestType

smallestType :: PrimType
smallestType = Bool

alignmentMap :: Imp.KernelCode  -> AlignmentMap
alignmentMap = HM.map alignment . Imp.memoryUsage (const mempty)
  where alignment = HS.foldr mostRestrictive smallestType
        mostRestrictive bt1 bt2 =
          if (primByteSize bt1 :: Int) > primByteSize bt2
          then bt1 else bt2

ensureAlignment :: AlignmentMap
                -> (VName, Imp.Size)
                -> (VName, Imp.Size, PrimType)
ensureAlignment alignments (name, size) =
  (name, size, lookupAlignment name alignments)

explodeOuterDimension :: Shape -> SubExp -> SubExp -> IxFun.IxFun -> IxFun.IxFun
explodeOuterDimension orig_shape n m ixfun =
  IxFun.reshape ixfun explode_dims
  where explode_dims = reshapeOuter [DimNew n, DimNew m] 1 orig_shape

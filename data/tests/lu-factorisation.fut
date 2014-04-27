// Compute LU-factorisation of matrix.

fun {*[[real]], *[[real]]} lu_inplace(*[[real]] a) =
  let n = size(0, a) in
  loop ({a,l,u} = {a,
                   replicate(n,replicate(n,0.0)),
                   replicate(n,replicate(n,0.0))}) =
    for k < n do
      let u[k,k] = a[k,k] in
      loop ({l,u}) = for i < n-k do
          let l[i+k,k] = a[i+k,k]/u[k,k] in
          let u[k,i+k] = a[k,i+k] in
          {l,u}
        in
      loop (a) = for i < n-k do
        loop (a) = for j < n-k do
          let a[i+k,j+k] = a[i+k,j+k] - l[i+k,k] * u[k,j+k] in
          a
        in a
      in {a,l,u}
    in
  {l,u}

fun {[[real]], [[real]]} main([[real]] a) =
  lu_inplace(copy(a))
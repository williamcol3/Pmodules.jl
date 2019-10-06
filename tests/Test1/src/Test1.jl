module Test1

using Pmodules
@Pmodule

@P import Test1.C: value
@P import Test1: B, A

a_value = A.value
b_value = B.value
c_value = value

end # module

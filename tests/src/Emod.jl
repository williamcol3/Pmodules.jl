# println("Including Emod")

# dump((@macroexpand @P module Emod
#     println("Defining Emod")
#     val = 1
# end), maxdepth=16)

module Emod
    using Pmodules

    @Pmodule

    println("Defining Emod")
    val = 1
end
# println("Including EmodJr")

# dump((@macroexpand @P module EmodJr
#     println("Defining EmodJr")

#     println("Importing EmodSr")
#     @macroexpand @P import EmodSr
# end), maxdepth=16)

module EmodJr
    println("Defining EmodJr")

    # println("Importing EmodSr")
    # dump(@macroexpand @P import Emod.EmodSr)
    # @P import EmodSr
end
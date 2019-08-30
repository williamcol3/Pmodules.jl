using Pmodules

# println("Including EmodSr")

# dump((@macroexpand @P module EmodSr
#     println("Defining EmodSr.")
# end), maxdepth=16)

module EmodSr
    using Pmodules

    println("Defining EmodSr.")
    @P import EmodJr

    println(fullname(EmodJr))
end
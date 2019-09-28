using Test

push!(LOAD_PATH, joinpath(@__DIR__, "Test1"))
import Test1

@testset "Test One" begin
    @test Test1.Test1Child.value == 1
    @test Test1.Test1Child.sibling_value == 2
end
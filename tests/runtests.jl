using Test

push!(LOAD_PATH, joinpath(@__DIR__, "Test1"))
import Test1

@testset "Test One" begin
    @test Test1.a_value == 1
    @test Test1.b_value == 2
    @test Test1.c_value == 3
end
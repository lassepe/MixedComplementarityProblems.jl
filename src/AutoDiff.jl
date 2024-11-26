""" Support for automatic differentiation of an MCP's solution (x, y) with respect
 to its parameters θ. Since a solution satisfies
                            F(z; θ, ϵ) = 0
for the primal-dual system, the derivative we are looking for is given by
                            ∂z∂θ = -(∇F_z)⁺ ∇F_θ.

Modifed from https://github.com/JuliaGameTheoreticPlanning/ParametricMCPs.jl/blob/main/src/AutoDiff.jl.
"""

module AutoDiff

using ..MCPSolver: MCPSolver
using ChainRulesCore: ChainRulesCore
using ForwardDiff: ForwardDiff
using LinearAlgebra: LinearAlgebra
using SparseArrays: SparseArrays

using Infiltrator

function _solve_jacobian_θ(mcp::MCPSolver.PrimalDualMCP, solution, θ)
    !isnothing(mcp.∇F_θ) || throw(
        ArgumentError(
            "Missing sensitivities. Set `compute_sensitivities = true` when constructing the PrimalDualMCP.",
        ),
    )

    (; x, y, s, ϵ) = solution
    ∂z∂θ = -mcp.∇F_z(x, y, s; θ, ϵ) \ mcp.∇F_θ(x, y, s; θ, ϵ)

    SparseArrays.sparse(∂z∂θ)
end

function ChainRulesCore.rrule(
    ::typeof(MCPSolver.solve),
    solver_type::MCPSolver.SolverType,
    mcp::MCPSolver.PrimalDualMCP;
    θ,
    kwargs...,
)
    solution = MCPSolver.solve(solver_type, mcp; θ, kwargs...)
    project_to_θ = ChainRulesCore.ProjectTo(θ)

    function solve_pullback(∂solution)
        no_grad_args = (;
            ∂self = ChainRulesCore.NoTangent(),
            ∂solver_type = ChainRulesCore.NoTangent(),
            ∂mcp = ChainRulesCore.NoTangent(),
        )

        ∂θ = ChainRulesCore.@thunk let
            ∂z∂θ = _solve_jacobian_θ(mcp, solution, θ)
            ∂l∂x = ∂solution.x
            ∂l∂y = ∂solution.y
            ∂l∂s = ∂solution.s
            project_to_θ(∂z∂θ' * [∂l∂x; ∂l∂y; ∂l∂s])
        end

        no_grad_args..., ∂θ
    end

    solution, solve_pullback
end

function MCPSolver.solve(
    solver_type::MCPSolver.SolverType,
    mcp::MCPSolver.PrimalDualMCP;
    θ::AbstractVector{<:ForwardDiff.Dual{T}},
    kwargs...,
) where {T}
    # strip off the duals
    θ_v = ForwardDiff.value.(θ)
    θ_p = ForwardDiff.partials.(θ)
    # forward pass
    solution = MCPSolver .. solve(solver_type, mcp; θ = θ_v, kwargs...)
    # backward pass
    ∂z∂θ = _solve_jacobian_θ(mcp, solution, θ_v)
    # downstream gradient
    z_p = ∂z∂θ * θ_p
    # glue forward and backward pass together into dual number types
    z_d = ForwardDiff.Dual{T}.(solution.z, z_p)
    x_d = @view z_d[1:(mcp.unconstrained_dimension)]
    y_d =
        (@view z_d[(mcp.unconstrained_dimension + 1):(mcp.unconstrained_dimension + mcp.constrained_dimension)])
    s_d = @view z_d[(mcp.unconstrained_dimension + mcp.constrained_dimension + 1):end]

    (; solution.status, solution.kkt_error, solution.ϵ, x = x_d, y = y_d, s = s_d)
end

end

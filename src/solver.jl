abstract type SolverType end
struct InteriorPoint <: SolverType end

using Infiltrator: @infiltrate

""" Basic interior point solver, based on Nocedal & Wright, ch. 19.
Computes step directions `δz` by solving the relaxed primal-dual system, i.e.
                         ∇F(z; ϵ) δz = -F(z; ϵ).

Given a step direction `δz`, performs a "fraction to the boundary" linesearch,
i.e., for `(x, s)` it chooses step size `α_s` such that
              α_s = max(α ∈ [0, 1] : s + α δs ≥ (1 - τ) s)
and for `y` it chooses step size `α_s` such that
              α_y = max(α ∈ [0, 1] : y + α δy ≥ (1 - τ) y).

A typical value of τ is 0.995. Once we converge to ||F(z; \epsilon)|| ≤ ϵ,
we typically decrease ϵ by a factor of 0.1 or 0.2, with smaller values chosen
when the previous subproblem is solved in fewer iterations.
"""
function solve(
    ::InteriorPoint,
    mcp::PrimalDualMCP;
    x₀ = zeros(mcp.unconstrained_dimension),
    y₀ = ones(mcp.constrained_dimension),
    tol = 1e-4
)
    x = x₀
    y = y₀
    s = ones(length(y))

    ϵ = 10.0
    kkt_error = Inf
    while kkt_error > tol && ϵ > tol
        iters = 1
        while kkt_error > ϵ
            # Compute the Newton step.
            F = mcp.F(x, y, s; ϵ)
            δz = -(mcp.∇F(x, y, s; ϵ) + ϵ*I) \ F

            # Fraction to the boundary linesearch.
            δx = @view δz[1:mcp.unconstrained_dimension]
            δy = @view δz[(mcp.unconstrained_dimension + 1):(mcp.unconstrained_dimension + mcp.constrained_dimension)]
            δs = @view δz[(mcp.unconstrained_dimension + mcp.constrained_dimension + 1):end]

            α_s = fraction_to_the_boundary_linesearch(s, δs; tol)
            α_y = fraction_to_the_boundary_linesearch(y, δy; tol)

            if isnan(α_s) || isnan(α_y)
                @warn "Linesearch failed. Exiting prematurely."
                break
            end

            # Update variables accordingly.
            x += α_s * δx
            s += α_s * δs
            y += α_y * δy

            kkt_error = maximum(abs.(F))
            iters += 1
            @info iters, s
        end

        @info x
        @info y
        @info s
        @info ϵ
        ϵ *= 1 - exp(-iters)
    end

    (; x, y, s, kkt_error)
end

"""Helper function to compute the step size `α` which solves:
                   α* = max(α ∈ [0, 1] : v + α δ ≥ (1 - τ) v).
"""
function fraction_to_the_boundary_linesearch(v, δ; τ = 0.995, decay = 0.5, tol = 1e-4)
    α = 1.0
    while any(v + α * δ .< (1 - τ) * v)
        if α < tol
            return NaN
        end

        α *= decay
    end

    α
end
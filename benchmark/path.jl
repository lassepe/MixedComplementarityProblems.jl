""" Generate a random large (convex) quadratic problem of the form
                               min_x 0.5 xᵀ M x - θᵀ x
                               s.t.  Ax - b ≥ 0.
using Base: parameter_upper_bound

NOTE: the problem may not be feasible!
"""
function generate_test_problem(
    rng = Random.MersenneTwister(1);
    num_primals = 1000,
    num_inequalities = 1000,
)
    M = let
        P = randn(rng, num_primals, num_primals)
        P' * P
    end

    A = randn(rng, num_inequalities, num_primals)
    b = randn(rng, num_inequalities)

    G(x, y; θ) = M * x - θ - A' * y
    H(x, y; θ) = A * x - b
    K(z, θ) = begin
        x = z[1:size(M, 1)]
        y = z[(size(M, 1) + 1):end]

        [G(x, y; θ); H(x, y; θ)]
    end

    (; G, H, K)
end

"Benchmark interior point solver against PATH on a bunch of random QPs."
function benchmark(;
    num_problems = 10,
    num_samples_per_problem = 100,
    num_primals = 10,
    num_inequalities = 10,
)
    rng = Random.MersenneTwister(1)

    # Generate random problems and parameters.
    problems = @showprogress desc = "Generating test problems..." map(1:num_problems) do _
        generate_test_problem(rng; num_primals, num_inequalities)
    end

    θs = map(1:num_samples_per_problem) do _
        randn(rng, num_primals)
    end

    # Generate corresponding MCPs.
    ip_mcps = @showprogress desc = "Generating IP MCPs... " map(problems) do p
        MixedComplementarityProblems.PrimalDualMCP(
            p.G,
            p.H;
            unconstrained_dimension = num_primals,
            constrained_dimension = num_inequalities,
            parameter_dimension = num_primals,
        )
    end

    path_mcps = @showprogress desc = "Generating PATH MCPs..." map(problems) do p
        lower_bounds = [fill(-Inf, num_primals); fill(0, num_inequalities)]
        upper_bounds = fill(Inf, num_primals + num_inequalities)
        ParametricMCPs.ParametricMCP(p.K, lower_bounds, upper_bounds, num_primals)
    end

    ip = @showprogress desc = "Solving IP MCPs..." map(ip_mcps) do mcp
        # Make sure everything is compiled in a dry run.
        MixedComplementarityProblems.solve(
            MixedComplementarityProblems.InteriorPoint(),
            mcp,
            zeros(num_primals),
        )

        # Solve and time.
        map(θs) do θ
            elapsed_time = @elapsed sol = MixedComplementarityProblems.solve(
                MixedComplementarityProblems.InteriorPoint(),
                mcp,
                θ,
            )

            (; elapsed_time, success = sol.status == :solved)
        end
    end

    path = @showprogress desc = "Solving PATH MCPs..." map(path_mcps) do mcp
        # Make sure everything is compiled in a dry run.
        ParametricMCPs.solve(mcp, zeros(num_primals))

        # Solve and time.
        map(θs) do θ
            elapsed_time = @elapsed sol = ParametricMCPs.solve(mcp, θ)

            (; elapsed_time, success = sol.status == PATHSolver.MCP_Solved)
        end
    end

    (; ip, path)
end

"Compute summary statistics from solver benchmark data."
function summary_statistics(data)
    accumulate_stats(solver_data) = begin
        (; success_rate = fraction_solved(solver_data), runtime_stats(solver_data)...)
    end

    (; ip = accumulate_stats(data.ip), path = accumulate_stats(data.path))
end

"Estimate mean and standard deviation of runtimes for all problems."
function runtime_stats(solver_data)
    stats = map(solver_data) do problem_data
        filtered_times = map(
            datum -> datum.elapsed_time,
            filter(datum -> datum.success, problem_data),
        )
        μ = Statistics.mean(filtered_times)
        σ = Statistics.stdm(filtered_times, μ)

        (; μ, σ)
    end

    μ = map(datum -> datum.μ, stats)
    σ = map(datum -> datum.σ, stats)
    (; μ, σ, mean_μ = Statistics.mean(μ), mean_σ = Statistics.mean(σ))
end

"Compute fraction of problems solved."
function fraction_solved(solver_data)
    Statistics.mean(solver_data) do problem_data
        Statistics.mean(datum -> datum.success, problem_data)
    end
end

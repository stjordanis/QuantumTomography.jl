export fit,
       #fitA,
       #fitB,
       predict,
       FreeLSStateTomo,
       LSStateTomo,
       MLStateTomo

function build_state_predictor{T}(obs::Vector{Matrix{T}})
    return reduce(vcat,[vec(o)' for o in obs])
end

"""
`FreeLSStateTomo`

Free (unconstrained) least-squares state tomography algorithm. It is
constructed from a vector of observables corresponding to
measurements that are performed on the state being reconstructed.
"""
type FreeLSStateTomo
    inputdim::Int
    outputdim::Int
    pred::Matrix{Complex128}
    function FreeLSStateTomo(obs::Vector)
        pred = build_state_predictor(obs)
        outputdim = size(pred,1)
        inputdim = size(pred,2)
        new(inputdim,outputdim,pred)
    end
end

"""
`predict`

Predict outcomes of a tomography experiment for a given state (density matrix).
"""
function predict(method::FreeLSStateTomo, state)
    method.pred*vec(state)
end

"""
`fit(method, ...)`

Reconstruct a state from observations (i.e., perform state tomography). Exactly which fitting
routine is used depends on the type of the `method`. The possible types are

   + FreeLSStateTomo : unconstrained least-squares state tomography
   + LSStateTomo : least-squares state tomography constrained to physical states
   + MLStateTomo : maximum-likelihood, maximum-entropy state tomography constrained to physical states

"""
function fit(method::FreeLSStateTomo, means::Vector{Float64}, vars::Vector{Float64}=-ones(length(means)); algorithm=:OLS)
    if length(means) != method.outputdim
        error("The number of expected means does not match the required number of experiments")
    end
    d = round(Int, method.inputdim |> sqrt)
    if algorithm==:OLS
        reg = method.pred\means
        return reshape(reg,d,d), norm(method.pred*reg-means,2)/length(means), :Optimal
    elseif algorithm==:GLS
        if any(vars<0)
            error("Variances must be positive for generalized least squares.")
        end
        reg = (sqrt(vars)\method.pred)\means
        return reshape((sqrt(vars)\method.pred)\means,d,d), sqrt(dot(method.pred*reg-means,diagm(vars)\(method.pred*reg-means)))/length(means), :Optimal
    else
        error("Unrecognized method for least squares state tomography")
    end
end


"""
`LSStateTomo`

Type corresponding to constrained least-squares state tomography
algorithm. It is constructed from a vector of observables
corresponding to measurements that are performed on the state being
reconstructed.

The outcome of said measurements for a given density matrix ρ can be
computed using the `predict` function , while the density matrix can
be estimated from observations (including variances) by using the
`fit` function.

"""
type LSStateTomo
    inputdim::Int
    outputdim::Int
    realpred::Matrix{Float64}
    function LSStateTomo(obs::Vector)
        pred = build_state_predictor(obs)
        outputdim = size(pred,1)
        inputdim = size(pred,2)
        realpred = [real(pred) imag(pred)];
        new(inputdim,outputdim,realpred)
    end
end

function predict(method::LSStateTomo, state)
    (method.realpred[:,1:round(Int,end/2)]+1im*method.realpred[:,round(Int,end/2)+1:end])*vec(state)
end

function fit(method::LSStateTomo,
             means::Vector{Float64},
             vars::Vector{Float64};
             #solver = MosekSolver(LOG=0))
             solver = SCSSolver(verbose=0, max_iters=10_000, eps = 1e-8))

    if length(means) != length(vars) || method.outputdim != length(means)
        error("Size of observations and/or predictons do not match.")
    end
    dsq = method.inputdim
    d = round(Int,sqrt(dsq))

    # We assume that the predictions are always real-valued
    # and we need to do the complex->real translation manually since
    # Convex.jl does not support complex numbers yet
    ivars = 1./sqrt(vars)

    ρr = Variable(d,d)
    ρi = Variable(d,d)

    constraints = trace(ρr) == 1
    constraints += trace(ρi) == 0
    constraints += isposdef([ρr ρi; -ρi ρr])

    # TODO: use quad_form instead of vecnorm? Have 1/vars are diagonal quadratic form
    problem = minimize( vecnorm( (means - method.realpred*[vec(ρr); vec(ρi)]) .* ivars, 2), constraints )

    solve!(problem, solver)

    return (ρr.value - 1im*ρi.value), problem.optval^2, problem.status
end

"""
`MLStateTomo`

Maximum-likelihood maximum-entropy quantum state tomography algorithm. It is
constructed from a collection of observables corresponding to
measurements that are performed on the state being reconstructed, as
well as a hedging factor β. If β=0, no hedging is applied. If β > 0
either a log determinant or log minimum eigenvalue penalty is applied.

**AT THE MOMENT HEDGING IS ONLY APPLIED IN fitA, AND IS NOT CURRENTLY WORKING**
"""
type MLStateTomo
    effects::Vector{Matrix{Complex128}}
    dim::Int64
    β::Float64
    function MLStateTomo(v::Vector,β=0.0)
        for e in v
            if !ishermitian(e) || !ispossemidef(e) || real(trace(e))>1
                error("MLStateTomo state tomography is parameterized by POVM effects only.")
            end
        end
        if !all([size(e,1)==size(e,2) for e in v]) || !all([size(v[1],1)==size(e,1) for e in v])
                error("All effects must be square matrices, and they must have have the same dimension.")
        end
        if β < 0
            error("Hedging penalty must be positive.")
        end
        new(v,size(v[1],1),β)
    end
end

function predict(method::MLStateTomo,ρ)
    Float64[ real(trace(ρ*e)) for e in method.effects]
end

"""
`fitA(method::MLStateTomo, freq, solver=SCSSolver)`

This is a state tomography fitting routine using convex optimization. It's use is currently
discouraged simply because it is much slower than the iterative solver, and often does not
conver to a solution that meets the optimality criteria.
"""
function fitA(method::MLStateTomo,
             freq::Vector;
             #solver = MosekSolver(LOG=0))
             solver = SCSSolver(verbose=0, max_iters=100_000, eps = 1e-8))

    if length(method.effects) != length(freq)
        error("Vector of counts and vector of effects must have same length, but length(counts) == $(length(counts)) != $(length(method.effects))")
    end

    d = method.dim

    # ρr = Variable(d,d)
    ρr = Semidefinite(d)
    ρi = Variable(d,d)

    ϕ(m) = [real(m) -imag(m); imag(m) real(m)];
    ϕ(r,i) = [r i; -i r]

    obj = freq[1] * log(trace([ρr ρi; -ρi ρr]*ϕ(method.effects[1])))
    for i=2:length(method.effects)
        obj += freq[i] * log(trace([ρr ρi; -ρi ρr]*ϕ(method.effects[i])))
    end
    # add hedging regularization
    if method.β != 0.0
        obj += method.β*log(lambdamin([ρr ρi; -ρi ρr]))
    end

    constraints = trace(ρr) == 1
    constraints += trace(ρi) == 0
    constraints += isposdef([ρr ρi; -ρi ρr])

    problem = maximize(obj, constraints)

    solve!(problem, solver)

    return ρr.value-im*ρi.value, problem.optval, problem.status
end

"""
`fitB(method::MLStateTomo, freq, solver=SCSSolver)`

This is a state tomography fitting routine using convex optimization. It's use is currently
discouraged simply because it is much slower than the iterative solver, and often does not
conver to a solution that meets the optimality criteria, much like fitB.
"""
function fitB(method::MLStateTomo,
             freq::Vector;
             #solver = MosekSolver(LOG=0))
             solver = SCSSolver(verbose=0, max_iters=100_000, eps = 1e-8))

    if length(method.effects) != length(freq)
        error("Vector of counts and vector of effects must have same length, but length(counts) == $(length(counts)) != $(length(method.effects))")
    end

    d = method.dim

    ρr = Semidefinite(d) #Variable(d,d)
    ρi = Variable(d,d)
    p  = Variable(length(method.effects),Positive())

    ϕ(m) = [real(m) -imag(m); imag(m) real(m)];
    ϕ(r,i) = [r i; -i r]
    obj = freq[1] * log(p[1])
    for i=2:length(method.effects)
        obj += freq[i] * log(p[i])
    end
    #obj += method.β!=0.0 ? method.β*logdet([ρr ρi; -ρi ρr]) : 0.0
    #obj += method.β!=0.0 ? method.β*log(lambdamin([ρr ρi; -ρi ρr])) : 0.0

    constraints = trace(ρr) == 1
    constraints += trace(ρi) == 0
    for i=1:length(method.effects)
        constraints += p[i] == trace([ρr ρi; -ρi ρr]*ϕ(method.effects[i]))/2
    end
    constraints += isposdef([ρr ρi; -ρi ρr])

    problem = maximize(obj, constraints)

    solve!(problem, solver)

    return ρr.value-im*ρi.value, problem.optval, problem.status
end

function R(ρ,E,obs)
    pr = Float64[real(trace(ρ*Ei)) for Ei in E]
    R = obs[1]/pr[1]*E[1]
    for i in 2:length(E)
        R += obs[i]/pr[i]*E[i]
    end
    R
end

function LL(ρ,E,obs)
    pr = Float64[real(trace(ρ*Ei)) for Ei in E]
    sum(obs.*log(pr))
end

function fit(method::MLStateTomo,
             freq::Vector;
             δ=.005, # a more natural parameterization of "dilution"
             λ=0.0,  # entropy penalty
             tol=1e-9,
             maxiter=100_000,
             ρ0 = eye(Complex128,method.dim))
    ϵ=1/δ
    iter = 1
    ρk = copy(ρ0)
    ρktemp = similar(ρk)
    ρkm = similar(ρ0) #Array(Complex128,method.dim,method.dim)
    status = :Optimal
    while true
        copy!(ρkm,ρk)
        if iter >= maxiter
            status = :MaxIter
            break
        end
        # diluted iterative scheme for ML (from PRA 75 042108 2007)
        Tk = λ > 0.0 ?
             (1+ϵ*(R(ρk,method.effects,freq)-eye(method.dim)-λ*(logm(ρk)-trace(ρk*logm(ρk)))))/(1+ϵ) :
             (1+ϵ*R(ρk,method.effects,freq))/(1+ϵ)
        A_mul_B!(ρktemp,ρk,(1+ϵ*Tk)/(1+ϵ)) # ρk = ρk * (1+ϵRk)/(1+ϵ)
        A_mul_B!(ρk,(1+ϵ*Tk)/(1+ϵ),ρktemp) # ρk = (1+ϵRk) * ρk/(1+ϵ)
        trnormalize!(ρk)
        if vecnorm(ρk-ρkm)/method.dim^2 < tol
            status = :Optimal
            break
        end
        iter += 1
    end
    return ρk, LL(ρk,method.effects,freq), status
end

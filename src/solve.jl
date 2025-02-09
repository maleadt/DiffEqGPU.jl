"""
```julia
vectorized_solve(probs, prob::Union{ODEProblem, SDEProblem}alg;
                 dt, saveat = nothing,
                 save_everystep = true,
                 debug = false, callback = CallbackSet(nothing), tstops = nothing)
```

A lower level interface to the kernel generation solvers of EnsembleGPUKernel with fixed
time-stepping.

## Arguments

  - `probs`: the GPU-setup problems generated by the ensemble.
  - `prob`: the quintessential problem form. Can be just `probs[1]`
  - `alg`: the kernel-based differential equation solver. Must be one of the
    EnsembleGPUKernel specialized methods.

## Keyword Arguments

Only a subset of the common solver arguments are supported.
"""
function vectorized_solve end

function vectorized_solve(probs, prob::ODEProblem, alg;
    dt, saveat = nothing,
    save_everystep = true,
    debug = false, callback = CallbackSet(nothing), tstops = nothing,
    kwargs...)
    backend = get_backend(probs)
    backend = maybe_prefer_blocks(backend)
    # if saveat is specified, we'll use a vector of timestamps.
    # otherwise it's a matrix that may be different for each ODE.
    timeseries = prob.tspan[1]:dt:prob.tspan[2]
    nsteps = length(timeseries)

    dt = convert(eltype(prob.tspan), dt)

    if saveat === nothing
        if save_everystep
            len = length(prob.tspan[1]:dt:prob.tspan[2])
            if tstops !== nothing
                len += length(tstops) - count(x -> x in tstops, timeseries)
                nsteps += length(tstops) - count(x -> x in tstops, timeseries)
            end
        else
            len = 2
        end
        ts = allocate(backend, typeof(dt), (len, length(probs)))
        fill!(ts, prob.tspan[1])
        us = allocate(backend, typeof(prob.u0), (len, length(probs)))
    else
        saveat = adapt(backend, saveat)
        ts = allocate(backend, typeof(dt), (length(saveat), length(probs)))
        fill!(ts, prob.tspan[1])
        us = allocate(backend, typeof(prob.u0), (length(saveat), length(probs)))
    end

    tstops = adapt(backend, tstops)

    kernel = ode_solve_kernel(backend)

    if backend isa CPU
        @warn "Running the kernel on CPU"
    end

    kernel(probs, alg, us, ts, dt, callback, tstops, nsteps, saveat,
        Val(save_everystep);
        ndrange = length(probs))

    # we build the actual solution object on the CPU because the GPU would create one
    # containig CuDeviceArrays, which we cannot use on the host (not GC tracked,
    # no useful operations, etc). That's unfortunate though, since this loop is
    # generally slower than the entire GPU execution, and necessitates synchronization
    #EDIT: Done when using with DiffEqGPU
    ts, us
end

# SDEProblems over GPU cannot support u0 as a Number type, because GPU kernels compiled only through u0 being StaticArrays
function vectorized_solve(probs, prob::SDEProblem, alg;
    dt, saveat = nothing,
    save_everystep = true,
    debug = false,
    kwargs...)
    backend = get_backend(probs)
    backend = maybe_prefer_blocks(backend)

    dt = convert(eltype(prob.tspan), dt)

    if saveat === nothing
        if save_everystep
            len = length(prob.tspan[1]:dt:prob.tspan[2])
        else
            len = 2
        end
        ts = allocate(backend, typeof(dt), (len, length(probs)))
        fill!(ts, prob.tspan[1])
        us = allocate(backend, typeof(prob.u0), (len, length(probs)))
    else
        saveat = adapt(backend, saveat)
        ts = allocate(backend, typeof(dt), (length(saveat), length(probs)))
        fill!(ts, prob.tspan[1])
        us = allocate(backend, typeof(prob.u0), (length(saveat), length(probs)))
    end

    if alg isa GPUEM
        kernel = em_kernel(backend)
    elseif alg isa Union{GPUSIEA}
        SciMLBase.is_diagonal_noise(prob) ? nothing :
        error("The algorithm is not compatible with the chosen noise type. Please see the documentation on the solver methods")
        kernel = siea_kernel(backend)
    end

    if backend isa CPU
        @warn "Running the kernel on CPU"
    end

    kernel(probs, us, ts, dt, saveat, Val(save_everystep);
        ndrange = length(probs))
    ts, us
end

"""
```julia
vectorized_asolve(probs, prob::ODEProblem, alg;
                  dt = 0.1f0, saveat = nothing,
                  save_everystep = false,
                  abstol = 1.0f-6, reltol = 1.0f-3,
                  callback = CallbackSet(nothing), tstops = nothing)
```

A lower level interface to the kernel generation solvers of EnsembleGPUKernel with adaptive
time-stepping.

## Arguments

  - `probs`: the GPU-setup problems generated by the ensemble.
  - `prob`: the quintessential problem form. Can be just `probs[1]`
  - `alg`: the kernel-based differential equation solver. Must be one of the
    EnsembleGPUKernel specialized methods.

## Keyword Arguments

Only a subset of the common solver arguments are supported.
"""
function vectorized_asolve end

function vectorized_asolve(probs, prob::ODEProblem, alg;
    dt = 0.1f0, saveat = nothing,
    save_everystep = false,
    abstol = 1.0f-6, reltol = 1.0f-3,
    debug = false, callback = CallbackSet(nothing), tstops = nothing,
    kwargs...)
    backend = get_backend(probs)
    backend = maybe_prefer_blocks(backend)

    dt = convert(eltype(prob.tspan), dt)
    abstol = convert(eltype(prob.tspan), abstol)
    reltol = convert(eltype(prob.tspan), reltol)
    # if saveat is specified, we'll use a vector of timestamps.
    # otherwise it's a matrix that may be different for each ODE.
    if saveat === nothing
        if save_everystep
            error("Don't use adaptive version with saveat == nothing and save_everystep = true")
        else
            len = 2
        end
        # if tstops !== nothing
        #     len += length(tstops)
        # end
        ts = allocate(backend, typeof(dt), (len, length(probs)))
        fill!(ts, prob.tspan[1])
        us = allocate(backend, typeof(prob.u0), (len, length(probs)))
    else
        saveat = adapt(backend, saveat)
        ts = allocate(backend, typeof(dt), (length(saveat), length(probs)))
        fill!(ts, prob.tspan[1])
        us = allocate(backend, typeof(prob.u0), (length(saveat), length(probs)))
    end

    us = adapt(backend, us)
    ts = adapt(backend, ts)
    tstops = adapt(backend, tstops)

    kernel = ode_asolve_kernel(backend)

    if backend isa CPU
        @warn "Running the kernel on CPU"
    end

    kernel(probs, alg, us, ts, dt, callback, tstops,
        abstol, reltol, saveat, Val(save_everystep);
        ndrange = length(probs))

    # we build the actual solution object on the CPU because the GPU would create one
    # containig CuDeviceArrays, which we cannot use on the host (not GC tracked,
    # no useful operations, etc). That's unfortunate though, since this loop is
    # generally slower than the entire GPU execution, and necessitates synchronization
    #EDIT: Done when using with DiffEqGPU
    ts, us
end

function vectorized_asolve(probs, prob::SDEProblem, alg;
    dt, saveat = nothing,
    save_everystep = true,
    debug = false,
    kwargs...)
    error("Adaptive time-stepping is not supported yet with GPUEM.")
end

# saveat is just a bool here:
#  true: ts is a vector of timestamps to read from
#  false: each ODE has its own timestamps, so ts is a vector to write to
@kernel function ode_solve_kernel(@Const(probs), alg, _us, _ts, dt, callback,
    tstops, nsteps,
    saveat, ::Val{save_everystep}) where {save_everystep}
    i = @index(Global, Linear)

    # get the actual problem for this thread
    prob = @inbounds probs[i]

    # get the input/output arrays for this thread
    ts = @inbounds view(_ts, :, i)
    us = @inbounds view(_us, :, i)

    _saveat = get(prob.kwargs, :saveat, nothing)

    saveat = _saveat === nothing ? saveat : _saveat

    integ = init(alg, prob.f, false, prob.u0, prob.tspan[1], dt, prob.p, tstops,
        callback, save_everystep, saveat)

    u0 = prob.u0
    tspan = prob.tspan

    integ.cur_t = 0
    if saveat !== nothing
        integ.cur_t = 1
        if prob.tspan[1] == saveat[1]
            integ.cur_t += 1
            @inbounds us[1] = u0
        end
    else
        @inbounds ts[integ.step_idx] = prob.tspan[1]
        @inbounds us[integ.step_idx] = prob.u0
    end

    integ.step_idx += 1
    # FSAL
    while integ.t < tspan[2] && integ.retcode != DiffEqBase.ReturnCode.Terminated
        saved_in_cb = step!(integ, ts, us)
        !saved_in_cb && savevalues!(integ, ts, us)
    end
    if integ.t > tspan[2] && saveat === nothing
        ## Intepolate to tf
        @inbounds us[end] = integ(tspan[2])
        @inbounds ts[end] = tspan[2]
    end

    if saveat === nothing && !save_everystep
        @inbounds us[2] = integ.u
        @inbounds ts[2] = integ.t
    end
end

@kernel function ode_asolve_kernel(probs, alg, _us, _ts, dt, callback, tstops,
    abstol, reltol,
    saveat,
    ::Val{save_everystep}) where {save_everystep}
    i = @index(Global, Linear)

    # get the actual problem for this thread
    prob = @inbounds probs[i]
    # get the input/output arrays for this thread
    ts = @inbounds view(_ts, :, i)
    us = @inbounds view(_us, :, i)
    # TODO: optimize contiguous view to return a CuDeviceArray

    _saveat = get(prob.kwargs, :saveat, nothing)

    saveat = _saveat === nothing ? saveat : _saveat

    u0 = prob.u0
    tspan = prob.tspan
    f = prob.f
    p = prob.p

    t = tspan[1]
    tf = prob.tspan[2]

    integ = init(alg, prob.f, false, prob.u0, prob.tspan[1], prob.tspan[2], dt,
        prob.p,
        abstol, reltol, DiffEqBase.ODE_DEFAULT_NORM, tstops, callback,
        saveat)

    integ.cur_t = 0
    if saveat !== nothing
        integ.cur_t = 1
        if tspan[1] == saveat[1]
            integ.cur_t += 1
            @inbounds us[1] = u0
        end
    else
        @inbounds ts[1] = tspan[1]
        @inbounds us[1] = u0
    end

    while integ.t < tspan[2] && integ.retcode != DiffEqBase.ReturnCode.Terminated
        saved_in_cb = step!(integ, ts, us)
        !saved_in_cb && savevalues!(integ, ts, us)
    end

    if integ.t > tspan[2] && saveat === nothing
        ## Intepolate to tf
        @inbounds us[end] = integ(tspan[2])
        @inbounds ts[end] = tspan[2]
    end

    if saveat === nothing && !save_everystep
        @inbounds us[2] = integ.u
        @inbounds ts[2] = integ.t
    end
end

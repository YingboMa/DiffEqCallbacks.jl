# Keep ODE solution in a domain specified by a function. Inspired by:
# Shampine, L.F., S. Thompson, J.A. Kierzenka, and G.D. Byrne, "Non-negative solutions
# of ODEs," Applied Mathematics and Computation Vol. 170, 2005, pp. 556-569.

# type definitions

abstract type AbstractDomainAffect{T,S,uType} end

struct PositiveDomainAffect{T,S,uType} <: AbstractDomainAffect{T,S,uType}
    abstol::T
    scalefactor::S
    u::uType
end

struct GeneralDomainAffect{autonomous,F,T,S,uType} <: AbstractDomainAffect{T,S,uType}
    g::F
    abstol::T
    scalefactor::S
    u::uType
    resid::uType

    function GeneralDomainAffect{autonomous}(g::F, abstol::T, scalefactor::S, u::uType,
                                             resid::uType) where {autonomous,F,T,S,uType}
        new{autonomous,F,T,S,uType}(g, abstol, scalefactor, u, resid)
    end
end

# definitions of callback functions

# Workaround since it is not possible to add methods to an abstract type:
# https://github.com/JuliaLang/julia/issues/14919
(f::PositiveDomainAffect)(integrator) = affect!(integrator, f)
(f::GeneralDomainAffect)(integrator) = affect!(integrator, f)

# general method defintions for domain callbacks

"""
    affect!(integrator, f::AbstractDomainAffect)

Apply domain callback `f` to `integrator`.
"""
function affect!(integrator, f::AbstractDomainAffect{T,S,uType}) where {T,S,uType}
    # modify u
    u_modified!(integrator, modify_u!(integrator, f))

    # define array of next time step, absolute tolerance, and scale factor
    if uType <: Void
        if typeof(integrator.u) <: Union{Number,SArray}
            u = integrator.u
        else
            u = similar(integrator.u)
        end
    else
        u = f.u
    end
    abstol = T <: Void ? integrator.opts.abstol : f.abstol
    scalefactor = S <: Void ? 1//2 : f.scalefactor

    # setup callback and save addtional arguments for checking next time step
    args = setup(f, integrator)

    # cache current time step
    dt = integrator.dt
    dt_modified = false
    p = integrator.p

    # update time step of integrator to proposed next time step
    integrator.dt = get_proposed_dt(integrator)

    # adjust time step to bounds and time stops
    fix_dt_at_bounds!(integrator)
    modify_dt_for_tstops!(integrator)
    t = integrator.t + integrator.dt

    while integrator.tdir * integrator.dt > 0
        # calculate estimated value of next step and its residuals
        if typeof(u) <: Union{Number,SArray}
            u = integrator(t)
        else
            integrator(u, t)
        end

        # check whether time step is accepted
        isaccepted(u, p, t, abstol, f, args...) && break

        # reduce time step
        dtcache = integrator.dt
        integrator.dt *= scalefactor
        dt_modified = true

        # adjust new time step to bounds and time stops
        fix_dt_at_bounds!(integrator)
        modify_dt_for_tstops!(integrator)
        t = integrator.t + integrator.dt

        # abort iteration when time step is not changed
        if dtcache == integrator.dt
            if integrator.opts.verbose
                warn("Could not restrict values to domain. Iteration was canceled since ",
                     "time step dt = ", integrator.dt, " could not be reduced.")
            end
            break
        end
    end

    # update current and next time step
    if dt_modified # add safety factor since guess is based on extrapolation
        set_proposed_dt!(integrator, 9//10*integrator.dt)
    else
        set_proposed_dt!(integrator, integrator.dt)
    end
    integrator.dt = dt
end

"""
    modify_u!(integrator, f::AbstractDomainAffect)

Modify current state vector `u` of `integrator` if required, and return whether it actually
was modified.
"""
modify_u!(integrator, ::AbstractDomainAffect) = false

"""
    setup(f::AbstractDomainAffect, integrator)

Setup callback `f` and return an arbitrary tuple whose elements are used as additional
arguments in checking whether time step is accepted.
"""
setup(::AbstractDomainAffect, integrator) = ()

"""
    isaccepted(u, abstol, f::AbstractDomainAffect, args...)

Return whether `u` is an acceptable state vector at the next time point given absolute
tolerance `abstol`, callback `f`, and other optional arguments.
"""
isaccepted(u, p, t, tolerance, ::AbstractDomainAffect, args...) = true

# specific method definitions for positive domain callback

function modify_u!(integrator, f::PositiveDomainAffect)
    # set all negative values to zero
    _set_neg_zero!(integrator,integrator.u) # Returns true if modified
end

function _set_neg_zero!(integrator,u::AbstractArray)
    modified = false
    @inbounds for i in eachindex(integrator.u)
        if integrator.u[i] < 0
            integrator.u[i] = 0
            modified = true
        end
    end
    modified
end

function _set_neg_zero!(integrator,u::Number)
    modified = false
    if integrator.u < 0
        integrator.u = 0
        modified = true
    end
    modified
end

function _set_neg_zero!(integrator,u::SArray)
    modified = false
    @inbounds for i in eachindex(integrator.u)
        if u[i] < 0
            u = setindex(u,zero(first(u)),i)
            modified = true
        end
    end
    modified && (integrator.u = u)
    modified
end

# state vector is accepted if its entries are greater than -abstol
isaccepted(u, p, t, abstol::Number, ::PositiveDomainAffect) = all(x -> x + abstol > 0, u)
isaccepted(u, p, t, abstol, ::PositiveDomainAffect) = all(x + y > 0 for (x,y) in zip(u, abstol))

# specific method definitions for general domain callback

# create array of residuals
setup(f::GeneralDomainAffect, integrator) =
    typeof(f.resid) <: Void ? (similar(integrator.u),) : (f.resid,)

function isaccepted(u, p, t, abstol, f::GeneralDomainAffect{autonomous,F,T,S,uType},
                    resid) where {autonomous,F,T,S,uType}
    # calculate residuals
    if autonomous
        f.g(resid, u)
    else
        f.g(resid, u, p, t)
    end

    # accept time step if residuals are smaller than the tolerance
    if typeof(abstol) <: Number
        all(x-> x < abstol, resid)
    else
        # element-wise comparison
        all(x < y for (x,y) in zip(resid, abstol))
    end
end

# callback definitions

function GeneralDomain(g, u=nothing; nlsolve=NLSOLVEJL_SETUP(), save=true,
                       abstol=nothing, scalefactor=nothing, autonomous=numargs(g)==2,
                       nlopts=Dict(:ftol => 10*eps()))
    if typeof(u) <: Void
        affect! = GeneralDomainAffect{autonomous}(g, abstol, scalefactor, nothing, nothing)
    else
        affect! = GeneralDomainAffect{autonomous}(g, abstol, scalefactor, deepcopy(u),
                                                  deepcopy(u))
    end
    condition = (u,t,integrator) -> true
    CallbackSet(ManifoldProjection(g; nlsolve=nlsolve, save=false,
                                   autonomous=autonomous, nlopts=nlopts),
                DiscreteCallback(condition, affect!; save_positions=(false, save)))
end

function PositiveDomain(u=nothing; save=true, abstol=nothing, scalefactor=nothing)
    if typeof(u) <: Void
        affect! = PositiveDomainAffect(abstol, scalefactor, nothing)
    else
        affect! = PositiveDomainAffect(abstol, scalefactor, deepcopy(u))
    end
    condition = (u,t,integrator) -> true
    DiscreteCallback(condition, affect!; save_positions=(false, save))
end

export GeneralDomain, PositiveDomain

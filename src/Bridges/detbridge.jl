function trimap(i::Integer, j::Integer)
    if i < j
        trimap(j, i)
    else
        div((i-1)*i, 2) + j
    end
end

"""
    extract_eigenvalues(model, f::MOI.VectorAffineFunction{T}, d::Int) where T

The vector `f` contains `t` followed by the matrix `X` of dimension `d`.
This functions extracts the eigenvalues of `X` and returns `t`,
a vector `MOI.VariableIndex` containing the eigenvalues of `X`,
the variables created and the index of the constraint created to extract the eigenvalues.
"""
function extract_eigenvalues(model, f::MOI.VectorAffineFunction{T}, d::Int) where T
    n = trimap(d, d)
    N = trimap(2d, 2d)

    Δ = MOI.addvariables!(model, n)

    X = MOIU.eachscalar(f)[2:(n+1)]
    m = length(X.terms)
    M = m + n + d

    terms = Vector{MOI.VectorAffineTerm{T}}(undef, M)
    terms[1:m] = X.terms
    constant = zeros(T, N); constant[1:n] = X.constants

    cur = m
    for j in 1:d
        for i in j:d
            cur += 1
            terms[cur] = MOI.VectorAffineTerm(trimap(i, d+j), MOI.ScalarAffineTerm(one(T), Δ[trimap(i, j)]))
        end
        cur += 1
            terms[cur] = MOI.VectorAffineTerm(trimap(d+j, d+j), MOI.ScalarAffineTerm(one(T), Δ[trimap(j, j)]))
    end
    @assert cur == M
    Y = MOI.VectorAffineFunction(terms, constant)
    sdindex = MOI.addconstraint!(model, Y, MOI.PositiveSemidefiniteConeTriangle(2d))

    t = MOIU.eachscalar(f)[1]
    D = Δ[trimap.(1:d, 1:d)]
    t, D, Δ, sdindex
end

"""
    LogDetBridge{T}

The `LogDetConeTriangle` is representable by a `PositiveSemidefiniteConeTriangle` and `ExponentialCone` constraints.
Indeed, ``\\log\\det(X) = \\log(\\delta_1) + \\cdots + \\log(\\delta_n)`` where ``\\delta_1``, ..., ``\\delta_n`` are the eigenvalues of ``X``.
Adapting, the method from [1, p. 149], we see that ``t \\le \\log(\\det(X))`` if and only if there exists a lower triangular matrix ``Δ`` such that
```math
\\begin{align*}
  \\begin{pmatrix}
    X & Δ\\\\
    Δ^\\top & \\mathrm{Diag}(Δ)
  \\end{pmatrix} & \\succeq 0\\\\
  t & \\le \\log(Δ_{11}) + \\log(Δ_{22}) + \\cdots + \\log(Δ_{nn})
\\end{align*}
```

[1] Ben-Tal, Aharon, and Arkadi Nemirovski. *Lectures on modern convex optimization: analysis, algorithms, and engineering applications*. Society for Industrial and Applied Mathematics, 2001.
```
"""
struct LogDetBridge{T} <: AbstractBridge
    Δ::Vector{VI}
    l::Vector{VI}
    sdindex::CI{MOI.VectorAffineFunction{T}, MOI.PositiveSemidefiniteConeTriangle}
    lcindex::Vector{CI{MOI.VectorAffineFunction{T}, MOI.ExponentialCone}}
    tlindex::CI{MOI.ScalarAffineFunction{T}, MOI.LessThan{T}}
end
function LogDetBridge{T}(model, f::MOI.VectorOfVariables, s::MOI.LogDetConeTriangle) where T
    LogDetBridge{T}(model, MOI.VectorAffineFunction{T}(f), s)
end
function LogDetBridge{T}(model, f::MOI.VectorAffineFunction{T}, s::MOI.LogDetConeTriangle) where T
    d = s.dimension
    t, D, Δ, sdindex = extract_eigenvalues(model, f, d)
    l = MOI.addvariables!(model, d)
    lcindex = sublog.(Ref(model), l, D, T)
    tlindex = subsum(model, t, l, T)

    LogDetBridge(Δ, l, sdindex, lcindex, tlindex)
end

MOI.supportsconstraint(::Type{LogDetBridge{T}}, ::Type{<:Union{MOI.VectorOfVariables, MOI.VectorAffineFunction{T}}}, ::Type{MOI.LogDetConeTriangle}) where T = true
addedconstrainttypes(::Type{LogDetBridge{T}}, ::Type{<:Union{MOI.VectorOfVariables, MOI.VectorAffineFunction{T}}}, ::Type{MOI.LogDetConeTriangle}) where T = [(MOI.VectorAffineFunction{T}, MOI.PositiveSemidefiniteConeTriangle), (MOI.VectorAffineFunction{T}, MOI.ExponentialCone), (MOI.ScalarAffineFunction{T}, MOI.LessThan{T})]

"""
    sublog(model, x::MOI.VariableIndex, z::MOI.VariableIndex, ::Type{T}) where T

Constrains ``x \\le \\log(z)`` and return the constraint index.
"""
function sublog(model, x::MOI.VariableIndex, z::MOI.VariableIndex, ::Type{T}) where T
    MOI.addconstraint!(model, MOI.VectorAffineFunction([MOI.VectorAffineTerm(1, MOI.ScalarAffineTerm(one(T), x)), MOI.VectorAffineTerm(3, MOI.ScalarAffineTerm(one(T), z))], [zero(T), one(T), zero(T)]), MOI.ExponentialCone())
end

"""
    subsum(model, t::MOI.ScalarAffineFunction, l::Vector{MOI.VariableIndex}, ::Type{T}) where T

Constrains ``t \\le l_1 + \\cdots + l_n`` where `n` is the length of `l` and return the constraint index.
"""
function subsum(model, t::MOI.ScalarAffineFunction, l::Vector{MOI.VariableIndex}, ::Type{T}) where T
    n = length(l)
    MOI.addconstraint!(model, MOI.ScalarAffineFunction([t.terms; MOI.ScalarAffineTerm.(-one(T), l)], zero(T)), MOI.LessThan(-t.constant))
end

# Attributes, Bridge acting as an model
MOI.get(b::LogDetBridge, ::MOI.NumberOfVariables) = length(b.Δ) + length(b.l)
MOI.get(b::LogDetBridge{T}, ::MOI.NumberOfConstraints{MOI.VectorAffineFunction{T}, MOI.PositiveSemidefiniteConeTriangle}) where T = 1
MOI.get(b::LogDetBridge{T}, ::MOI.NumberOfConstraints{MOI.VectorAffineFunction{T}, MOI.ExponentialCone}) where T = length(b.lcindex)
MOI.get(b::LogDetBridge{T}, ::MOI.NumberOfConstraints{MOI.ScalarAffineFunction{T}, MOI.LessThan{T}}) where T = 1
MOI.get(b::LogDetBridge{T}, ::MOI.ListOfConstraintIndices{MOI.VectorAffineFunction{T}, MOI.PositiveSemidefiniteConeTriangle}) where T = [b.sdindex]
MOI.get(b::LogDetBridge{T}, ::MOI.ListOfConstraintIndices{MOI.VectorAffineFunction{T}, MOI.ExponentialCone}) where T = b.lcindex
MOI.get(b::LogDetBridge{T}, ::MOI.ListOfConstraintIndices{MOI.ScalarAffineFunction{T}, MOI.LessThan{T}}) where T = [b.tlindex]

# References
function MOI.delete!(model::MOI.ModelLike, c::LogDetBridge)
    MOI.delete!(model, c.tlindex)
    MOI.delete!(model, c.lcindex)
    MOI.delete!(model, c.sdindex)
    MOI.delete!(model, c.l)
    MOI.delete!(model, c.Δ)
end

# Attributes, Bridge acting as a constraint
function MOI.canget(model::MOI.ModelLike, a::MOI.ConstraintPrimal, ::Type{LogDetBridge{T}}) where T
    MOI.canget(model, MOI.VariablePrimal(), MOI.VariableIndex) &&
    MOI.canget(model, a, CI{MOI.ScalarAffineFunction{T}, MOI.LessThan{T}}) &&
    MOI.canget(model, a, CI{MOI.VectorAffineFunction{T}, MOI.PositiveSemidefiniteConeTriangle})
end
function MOI.get(model::MOI.ModelLike, a::MOI.ConstraintPrimal, c::LogDetBridge)
    d = length(c.lcindex)
    Δ = MOI.get(model, MOI.VariablePrimal(), c.Δ)
    t = MOI.get(model, MOI.ConstraintPrimal(), c.tlindex) - sum(log.(Δ[trimap.(1:d, 1:d)]))
    x = MOI.get(model, MOI.ConstraintPrimal(), c.sdindex)[1:length(c.Δ)]
    [t; x]
end
MOI.canget(model::MOI.ModelLike, a::MOI.ConstraintDual, ::Type{<:LogDetBridge}) = false

# Constraints
MOI.canmodify(model::MOI.ModelLike, ::Type{<:LogDetBridge}, change) = false
MOI.canset(model::MOI.ModelLike, ::MOI.ConstraintSet, ::Type{<:LogDetBridge}) = false
MOI.canset(model::MOI.ModelLike, ::MOI.ConstraintFunction, ::Type{<:LogDetBridge}) = false

"""
    RootDetBridge{T}

The `RootDetConeTriangle` is representable by a `PositiveSemidefiniteConeTriangle` and an `GeometricMeanCone` constraints; see [1, p. 149].
Indeed, ``t \\le \\det(X)^(1/n)`` if and only if there exists a lower triangular matrix ``Δ`` such that
```math
\\begin{align*}
  \\begin{pmatrix}
    X & Δ\\\\
    Δ^\\top & \\mathrm{Diag}(Δ)
  \\end{pmatrix} & \\succeq 0\\\\
  t & \\le (Δ_{11} Δ_{22} \\cdots Δ_{nn})^{1/n}
\\end{align*}
```

[1] Ben-Tal, Aharon, and Arkadi Nemirovski. *Lectures on modern convex optimization: analysis, algorithms, and engineering applications*. Society for Industrial and Applied Mathematics, 2001.
"""
struct RootDetBridge{T} <: AbstractBridge
    Δ::Vector{VI}
    sdindex::CI{MOI.VectorAffineFunction{T}, MOI.PositiveSemidefiniteConeTriangle}
    gmindex::CI{MOI.VectorAffineFunction{T}, MOI.GeometricMeanCone}
end
function RootDetBridge{T}(model, f::MOI.VectorOfVariables, s::MOI.RootDetConeTriangle) where T
    RootDetBridge{T}(model, MOI.VectorAffineFunction{T}(f), s)
end
function RootDetBridge{T}(model, f::MOI.VectorAffineFunction{T}, s::MOI.RootDetConeTriangle) where T
    d = s.dimension
    t, D, Δ, sdindex = extract_eigenvalues(model, f, d)
    DF = MOI.VectorAffineFunction{T}(MOI.VectorOfVariables(D))
    gmindex = MOI.addconstraint!(model, MOIU.moivcat(t, DF), MOI.GeometricMeanCone(d+1))

    RootDetBridge(Δ, sdindex, gmindex)
end

MOI.supportsconstraint(::Type{RootDetBridge{T}}, ::Type{<:Union{MOI.VectorOfVariables, MOI.VectorAffineFunction{T}}}, ::Type{MOI.RootDetConeTriangle}) where T = true
addedconstrainttypes(::Type{RootDetBridge{T}}, ::Type{<:Union{MOI.VectorOfVariables, MOI.VectorAffineFunction{T}}}, ::Type{MOI.RootDetConeTriangle}) where T = [(MOI.VectorAffineFunction{T}, MOI.PositiveSemidefiniteConeTriangle), (MOI.VectorAffineFunction{T}, MOI.GeometricMeanCone)]

# Attributes, Bridge acting as an model
MOI.get(b::RootDetBridge, ::MOI.NumberOfVariables) = length(b.Δ)
MOI.get(b::RootDetBridge{T}, ::MOI.NumberOfConstraints{MOI.VectorAffineFunction{T}, MOI.PositiveSemidefiniteConeTriangle}) where T = 1
MOI.get(b::RootDetBridge{T}, ::MOI.NumberOfConstraints{MOI.VectorAffineFunction{T}, MOI.GeometricMeanCone}) where T = 1
MOI.get(b::RootDetBridge{T}, ::MOI.ListOfConstraintIndices{MOI.VectorAffineFunction{T}, MOI.PositiveSemidefiniteConeTriangle}) where T = [b.sdindex]
MOI.get(b::RootDetBridge{T}, ::MOI.ListOfConstraintIndices{MOI.VectorAffineFunction{T}, MOI.GeometricMeanCone}) where T = [b.gmindex]

# References
function MOI.delete!(model::MOI.ModelLike, c::RootDetBridge)
    MOI.delete!(model, c.gmindex)
    MOI.delete!(model, c.sdindex)
    MOI.delete!(model, c.Δ)
end

# Attributes, Bridge acting as a constraint
function MOI.canget(model::MOI.ModelLike, a::MOI.ConstraintPrimal, ::Type{RootDetBridge{T}}) where T
    MOI.canget(model, a, CI{MOI.VectorAffineFunction{T}, MOI.PositiveSemidefiniteConeTriangle}) &&
    MOI.canget(model, a, CI{MOI.VectorAffineFunction{T}, MOI.GeometricMeanCone})
end
function MOI.get(model::MOI.ModelLike, a::MOI.ConstraintPrimal, c::RootDetBridge)
    t = MOI.get(model, MOI.ConstraintPrimal(), c.gmindex)[1]
    x = MOI.get(model, MOI.ConstraintPrimal(), c.sdindex)[1:length(c.Δ)]
    [t; x]
end
MOI.canget(model::MOI.ModelLike, ::MOI.ConstraintDual, ::Type{<:RootDetBridge}) = false

# Constraints
MOI.canmodify(model::MOI.ModelLike, ::Type{<:RootDetBridge}, ::Type{<:MOI.AbstractFunctionModification}) = false
MOI.canset(model::MOI.ModelLike, ::MOI.ConstraintSet, ::Type{<:RootDetBridge}) = false
MOI.canset(model::MOI.ModelLike, ::MOI.ConstraintFunction, ::Type{<:RootDetBridge}) = false

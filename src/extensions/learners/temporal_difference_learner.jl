export TDLearner, DoubleLearner, DifferentialTDLearner, TDλReturnLearner

using LinearAlgebra:dot
using Distributions:pdf

"""
    TDLearner(approximator::Tapp, γ::Float64, optimizer::Float64; n::Int=0) where {Tapp<:AbstractVApproximator}
    TDLearner(approximator::Tapp, γ::Float64, optimizer::Float64; n::Int=0, method::Symbol=:SARSA) where {Tapp<:AbstractApproximator} 

The `TDLearner`(Temporal Difference Learner) use the latest `n` step experiences to update the `approximator`.

# Args

- `approximator`::[`AbstractApproximator`](@ref)
- Note that `n` starts with `0`, which means looking forward for the next `n` steps.
- `γ` is the discount rate of experience.
- `optimizer` is the learning rate.
- `method`. For [`VApproximator`](@ref), the only supported update method is `:SRS`, which means only **S**tates, **R**ewards and next_**S**ates are used to update the `approximator`. For [`QApproximator`](@ref), the following methods are supported:
    - `:SARS` (aka Q-Learning)
    - `:SARSA`
    - `:ExpectedSARSA`
"""
mutable struct TDLearner{Tapp<:AbstractApproximator,method,O} <: AbstractLearner
    approximator::Tapp
    γ::Float64
    optimizer::O
    n::Int

    function TDLearner(
        ;
        approximator::Tapp,
        γ = 1.0,
        optimizer = Descent(1.0),
        n = 0,
        method::Symbol = :SARSA,
    ) where {Tapp<:AbstractApproximator}
        if ApproximatorStyle(approximator) === VApproximator()
            if method != :SRS
                throw(ArgumentError("method [$method] is unsupported for a value approximator"))
            end
        elseif ApproximatorStyle(approximator) === QApproximator()
            if !in(method, [:SARSA, :SARS, :ExpectedSARSA])
                throw(ArgumentError("Supported methods are $supported_methods , your input is $method"))
            end
        else
            throw(ArgumentError("unknown approximator style"))
        end
        new{Tapp,method,typeof(optimizer)}(approximator, γ, optimizer, n)
    end
end

(learner::TDLearner)(obs) = learner.approximator(obs)
(learner::TDLearner)(obs, a) = learner.approximator(s, a)

RLBase.update!(learner::TDLearner{T, M}, experience) where {T, M} = update!(learner, ApproximatorStyle(learner.approximator), Val(M), experience)

RLBase.extract_experience(t::AbstractTrajectory, learner::TDLearner{T, M}) where {T, M} = extract_experience(t, learner, ApproximatorStyle(learner.approximator), Val(M))

#####
# SARSA
#####

function RLBase.update!(
    learner::TDLearner,
    ::QApproximator,
    ::Val{:SARSA},
    transitions::NamedTuple{(:states, :actions, :rewards, :terminals, :next_states, :next_actions)}
)
    states, actions, rewards, terminals, next_states, next_actions = transitions
    n, γ, Q, optimizer = learner.n, learner.γ, learner.approximator, learner.optimizer

    if length(terminals) > 0 && terminals[end]
        @views gains = discount_rewards(rewards[max(end - n, 1):end], γ)  # n starts with 0
        for (i, G) in enumerate(gains)
            @views s, a = states[end-length(gains)+i], actions[end-length(gains)+i]
            update!(Q, (s, a) => apply!(optimizer, (s, a), G - Q(s, a)))
        end
    else
        if length(states) ≥ (n + 1)  # n starts with 0
            @views s, a, s′, a′ = states[end-n],
                actions[end-n],
                next_states[end],
                next_actions[end]
            @views G = discount_rewards_reduced(rewards[end-n:end], γ) +
                       γ^(n + 1) * Q(s′, a′)
            update!(Q, (s, a) => apply!(optimizer, (s, a), G - Q(s, a)))
        end
    end
end

function RLBase.extract_experience(
    t::AbstractTrajectory,
    learner::TDLearner,
    ::QApproximator,
    ::Val{:SARSA},
)
    n, N = learner.n, length(t)
    # !!! n starts with 0
    if N > 0
        (
            states = select_last_dim(get_trace(t, :state), N-n:N),
            actions = select_last_dim(get_trace(t, :action), N-n:N),
            rewards = select_last_dim(get_trace(t, :reward), N-n:N),
            terminals = select_last_dim(get_trace(t, :terminal), N-n:N),
            next_states = select_last_dim(get_trace(t, :next_state), N-n:N),
            next_actions = select_last_dim(get_trace(t, :next_action), N-n:N),
        )
    else
        nothing
    end
end

#####
# ExpectedSARSA
#####

function RLBase.update!(
    learner::TDLearner,
    ::QApproximator,
    ::Val{:ExpectedSARSA},
    transitions::NamedTuple{(:states, :actions, :rewards, :terminals, :next_states, :prob_of_next_actions)}
)
    states, actions, rewards, terminals, next_states, probs_of_a′ = transitions
    n, γ, Q, optimizer = learner.n, learner.γ, learner.approximator, learner.optimizer

    if length(terminals) > 0 && terminals[end]
        @views gains = discount_rewards(rewards[max(end - n, 1):end], γ)  # n starts with 0
        for (i, G) in enumerate(gains)
            @views s, a = states[end-length(gains)+i], actions[end-length(gains)+i]
            update!(Q, (s, a) => apply!(optimizer, (s, a), G - Q(s, a)))
        end
    else
        if length(states) ≥ (n + 1)  # n starts with 0
            @views s, a, s′ = states[end-n], actions[end-n], next_states[end]
            @views G = discount_rewards_reduced(rewards[end-n:end], γ) +
                       γ^(n + 1) * dot(Q(s′), probs_of_a′)
            update!(Q, (s, a) => apply!(optimizer, (s, a), G - Q(s, a)))
        end
    end
end

function RLBase.extract_experience(
    t::AbstractTrajectory,
    policy::QBasedPolicy{<:TDLearner{<:AbstractApproximator,:ExpectedSARSA}}
)
    if length(t) > 0
        # !!! n starts with 0
        n, N = policy.learner.n, length(t)
        (
            states = select_last_dim(get_trace(t, :state), N-n:N),
            actions = select_last_dim(get_trace(t, :action), N-n:N),
            rewards = select_last_dim(get_trace(t, :reward), N-n:N),
            terminals = select_last_dim(get_trace(t, :terminal), N-n:N),
            next_states = select_last_dim(get_trace(t, :next_state), N-n:N),
            prob_of_next_actions = pdf(get_prob(policy, select_last_frame(get_trace(t, :next_state))))
        )
    else
        nothing
    end
end

#####
# SARS
#####

function RLBase.update!(
    learner::TDLearner,
    ::QApproximator,
    ::Val{:SARS},
    transitions::NamedTuple{(:states, :actions, :rewards, :terminals, :next_states)}
)
    states, actions, rewards, terminals, next_states = transitions
    n, γ, Q, optimizer = learner.n, learner.γ, learner.approximator, learner.optimizer

    if length(terminals) > 0 && terminals[end]
        @views gains = discount_rewards(rewards[max(end - n, 1):end], γ)  # n starts with 0
        for (i, G) in enumerate(gains)
            @views s, a = states[end-length(gains)+i], actions[end-length(gains)+i]
            update!(Q, (s, a) => apply!(optimizer, (s, a), G - Q(s, a)))
        end
    else
        if length(states) ≥ (n + 1)  # n starts with 0
            @views s, a, s′ = states[end-n], actions[end-n], next_states[end]
            @views G = discount_rewards_reduced(rewards[end-n:end], γ) +
                       γ^(n + 1) * maximum(Q(s′))  # n starts with 0
            update!(Q, (s, a) => apply!(optimizer, (s, a), G - Q(s, a)))
        end
    end
end

function RLBase.extract_experience(
    t::AbstractTrajectory,
    learner::TDLearner,
    ::QApproximator,
    ::Val{:SARS},
)
    n, N = learner.n, length(t)
    if length(t) > 0
        (
            states = select_last_dim(get_trace(t, :state), N-n:N),
            actions = select_last_dim(get_trace(t, :action), N-n:N),
            rewards = select_last_dim(get_trace(t, :reward), N-n:N),
            terminals = select_last_dim(get_trace(t, :terminal), N-n:N),
            next_states = select_last_dim(get_trace(t, :next_state), N-n:N),
        )
    else
        nothing
    end
end

#####
# SARS DoubleLearner
#####

function RLBase.update!(
    learner::DoubleLearner{T, T},
    transitions::NamedTuple{(:states, :actions, :rewards, :terminals, :next_states)},
) where {T<:TDLearner{<:AbstractApproximator,:SARS}}

    if rand(learner.rng, Bool)
        learner, target_learner = learner.L1, learner.L2
    else
        learner, target_learner = learner.L2, learner.L1
    end

    states, actions, rewards, terminals, next_states = transitions
    n, γ, Q, Qₜ, optimizer = learner.n,
        learner.γ,
        learner.approximator,
        target_learner.approximator,
        learner.optimizer

    if length(terminals) > 0 && terminals[end]
        @views gains = discount_rewards(rewards[max(end - n, 1):end], γ)  # n starts with 0
        for (i, G) in enumerate(gains)
            @views s, a = states[end-length(gains)+i], actions[end-length(gains)+i]
            update!(Q, (s, a) => apply!(optimizer, (s, a), G - Q(s, a)))
        end
    else
        if length(states) ≥ (n + 1)  # n starts with 0
            @views s, a, s′ = states[end-n], actions[end-n], next_states[end]
            @views G = discount_rewards_reduced(rewards[end-n:end], γ) +
                       γ^(n + 1) * Qₜ(s′, argmax(Q(s′)))
            update!(Q, (s, a) => apply!(optimizer, (s, a), G - Q(s, a)))
        end
    end
end

#####
# SRS
#####

RLBase.update!(
    learner::TDLearner,
    ::VApproximator,
    ::Val{:SRS},
    transitions::NamedTuple{(:states, :rewards, :terminals, :next_states)}
) = update!(learner, merge(transitions, (weights=nothing,)))

function RLBase.update!(
    learner::TDLearner,
    ::VApproximator,
    ::Val{:SRS},
    transitions::NamedTuple{(:states, :rewards, :terminals, :next_states, :weights)}
)
    states, rewards, terminals, next_states, weights = transitions
    n, γ, V, optimizer = learner.n, learner.γ, learner.approximator, learner.optimizer

    if length(terminals) > 0 && terminals[end]
        @views gains = discount_rewards(rewards[max(end - n, 1):end], γ)  # n starts with 0
        cum_weights = isnothing(weights) ? nothing : cumprod!(reverse(weights))
        for (i, G) in enumerate(gains)
            @views s = states[end-length(gains)+i]
            if isnothing(cum_weights)
                update!(V, s => apply!(optimizer, s, G - V(s)))
            else
                update!(V, s => apply!(optimizer, s, cum_weights[i] * (G - V(s))))
            end
        end
    else
        if length(states) ≥ (n + 1)  # n starts with 0
            @views G = discount_rewards_reduced(rewards[end-n:end], γ) +
                       γ^(n + 1) * V(next_states[end])
            @views s = states[end-n]
            w = isnothing(weights) ? 1.0 : reduce(*, weights)
            update!(V, s => apply!(optimizer, s, w * (G - V(s))))
        end
    end
end

function RLBase.extract_experience(
    t::AbstractTrajectory,
    learner::TDLearner,
    ::VApproximator,
    ::Val{:SRS},
)
    n, N = learner.n, length(t)
    if length(t) > 0
        (
            states = select_last_dim(get_trace(t, :state), N-n:N),
            rewards = select_last_dim(get_trace(t, :reward), N-n:N),
            terminals = select_last_dim(get_trace(t, :terminal), N-n:N),
            next_states = select_last_dim(get_trace(t, :next_state), N-n:N),
        )
    else
        nothing
    end
end

function RLBase.extract_experience(
    buffer::AbstractTrajectory,
    π::OffPolicy{<:VBasedPolicy{<:TDLearner{<:AbstractApproximator,:SRS}}},
)
    transitions = extract_experience(buffer, π.π_target.learner)
    if isnothing(transitions)
        nothing
    else
        n, N = π.π_target.learner.n, length(buffer)
        (
            states = transitions.states,
            actions = select_last_dim(get_trace(t, :action), N-n:N),
            rewards = transitions.rewards,
            terminals = transitions.terminals,
            next_states = transitions.next_states,
        )
    end
end
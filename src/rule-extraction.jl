
using SoleLearning: Consequent,
    Rule, antecedent, consequent, rule_metrics,
    Branch,
    AbstractDecisionTree, DecisionTreeNode, path_rule,
    DecisionList, list_paths

############################################################################################
# Convert path to rule
############################################################################################
# TODO move to SoleLearning
# Convert path to rule
# TODO: Fix the function
# TODO: Rename into convert(::Rule, Type{RuleNest}) ...
"""
    Convert a path in a rule
"""
function path_rule(path::AbstractVector{<:DecisionTreeNode})

    # Building antecedent
    function _build_formula(conjuncts::AbstractVector{<:DecisionTreeNode})
        if length(conjuncts) > 2
            SoleLogics.CONJUNCTION(tree(conjuncts[1]),_build_formula(conjuncts[2:end]))
        else
            SoleLogics.CONJUNCTION(tree(conjuncts[1]),tree(conjuncts[2]))
        end
    end

    # Antecedent of the rule
    ant = begin
        root = begin
            # Number of internal nodes in the path
            n_internal = length(path) - 1

            if n_internal == 0
                FNode(SoleLogics.TOP)
            elseif n_internal == 1
                tree(path[1])
            else
                _build_formula(path[1:(end-1)])
            end
        end

        Formula(root)
    end

    # Consequent of the rule
    cons = path[end]

    Rule{logic(ant),typeof(cons)}(ant, cons, (;))
end

############################################################################################
# List paths that represent rules of DecisionTree
############################################################################################
# TODO: Move to SoleLoearning/SoleModels

function negation_node(node::Branch)
    antecedent = antecedent(node)
    consequents = consequents(node)
    info = node.info

    Branch{logic(antecedent), typeof(consequents[1])}(antecedent,consequents,info)
end

"""
    List all paths of a decision tree by performing a tree traversal
"""

function list_paths(tree::DecisionTree)
    # tree(f) [where f is a Formula object] is used to
    # retrieve the root FNode of the formula(syntax) tree
    return list_paths(root(tree))
end

function list_paths(node::Branch)
    # NOTE: antecedent(node) or tree(antecedent(node)) to obtain a FNode?
    left_path  = [node]
    right_path = [negation_node(node)]
    return [
        list_paths(leftchild(node),  left_path)...,
        list_paths(rightchild(node), right_path)...,
    ]
end

function list_paths(node::F) where {F<:FinalOutcome}
    return [node]
end

function list_paths(node::Branch, this_path::AbstractVector)
    # NOTE: antecedent(node) or tree(antecedent(node)) to obtain a FNode?
    left_path  = [this_path..., node]
    right_path = [this_path..., negation_node(node)]
    return [
        list_paths(leftchild(node),  left_path)...,
        list_paths(rightchild(node), right_path)...,
    ]
end

function list_paths(node::F,this_path::AbstractVector) where {F<:FinalOutcome}
    return [[this_path..., node], ]
end


############################################################################################
######################## List rules cascade ################################################
############################################################################################
# TODO: Move to SoleLearning/SoleModels

"""
    List all rules of a decision tree by performing a tree traversal
"""

function list_rules_cascade(tree::DecisionTree)
    # tree(f) [where f is a Formula object] is used to
    # retrieve the root FNode of the formula(syntax) tree
    return list_rules_cascade(root(tree))
end

function list_rules_cascade(node::Branch{L,O}) where {L<:Logic,O<:Outcome}

    # cons_left + cons_right = all possible consequences
    cons_left = list_rules_cascade(leftchild(node))
    cons_right = list_rules_cascade(rightchild(node))

    return [
        [Rule{L,O}(antecedent(node),cons) for cons in cons_left]...,
        [Rule{L,O}(NEGATION(antecedent(node)),cons) for cons in cons_right]...,
    ]
end

function list_rules_cascade(node::F) where {F<:FinalOutcome}
    return [prediction(node)]
end

############################################################################################
# Rule evaluation
############################################################################################

# Evaluation for an antecedent
function evaluate_antecedent(decs::AbstractVector{<:Decision}, X::MultiFrameModalDataset)
    D = hcat([evaluate_decision(d, X) for d in decs]...)
    # If all values in a row is true, then true (and logical)
    return map(all, eachrow(D))
end

# Evaluation for a rule
function evaluate_rule(
    path::AbstractVector{<:DecisionTreeNode},
    X::MultiFrameModalDataset,
    Y::AbstractVector{<:Consequent}
)
    # Antecedent satisfaction. For each instances in X:
    #  - `false` when not satisfiable,
    #  - `true` when satisfiable.
    ant_sat = evaluate_antecedent(decision.(path[1:(end-1)]),X)

    # Indices of satisfiable instances
    idxs_sat = findall(ant_sat .== true)

    # Consequent satisfaction. For each instances in X:
    #  - `false` when not satisfiable,
    #  - `true` when satisfiable,
    #  - `nothing` when antecedent does not hold.
    cons_sat = begin
        cons_sat = Vector{Union{Bool, Nothing}}(fill(nothing, length(Y)))
        idxs_true = begin
            idx_cons = findall(prediction(path[end]) .== Y)
            intersect(idxs_sat,idx_cons)
        end
        idxs_false = begin
            idx_cons = findall(prediction(path[end]) .!= Y)
            intersect(idxs_sat,idx_cons)
        end
        cons_sat[idxs_true]  .= true
        cons_sat[idxs_false] .= false
        cons_sat
    end

    y_pred = begin
        y_pred = Vector{Union{Consequent, Nothing}}(fill(nothing, length(Y)))
        y_pred[idxs_sat] .= prediction(path[end])
        y_pred
    end

    return (;
        ant_sat   = ant_sat,
        idxs_sat  = idxs_sat,
        cons_sat  = cons_sat,
        y_pred    = y_pred,
    )
end

############################################################################################
# Rule extraction from random forest
############################################################################################

# Patch single-frame _-> multi-frame
extract_rules(model::Any, X::ModalDataset, args...; kwargs...) =
    extract_rules(model, MultiFrameModalDataset(X), args...; kwargs...)

# Extract rules from a forest, with respect to a dataset
# TODO: SoleLogics.True
function extract_rules(
        forest::DecisionForest,
        X::MultiFrameModalDataset,
        Y::AbstractVector{<:Consequent};
        prune_rules = false,
        s = nothing,
        decay_threshold = nothing,
        #
        method = :CBC,
        min_frequency = nothing,
)

    isnothing(s) && (s = 1.0e-6)
    isnothing(decay_threshold) && (decay_threshold = 0.05)
    isnothing(min_frequency) && (min_frequency = 0.01)

    """
        prune_pathset(pathset::AbstractVector{<:AbstractVector{<:DecisionTreeNode}})
            -> AbstractVector{<:AbstractVector{<:DecisionTreeNode}}

        Prune the paths in pathset with error metric

    # Arguments
    - `pathset::AbstractVector{<:AbstractVector{<:DecisionTreeNode}}`: paths to prune

    # Returns
    - `AbstractVector{<:AbstractVector{<:DecisionTreeNode}}`: paths after the prune
    """
    function prune_pathset(
        pathset::AbstractVector{<:AbstractVector{<:DecisionTreeNode}}
    )
        [begin
            E_zero = rule_metrics(path, X, Y)[:error]

            for idx in (length(path)-1):1
                # Indices to be considered to evaluate the rule
                other_idxs = vcat(1:(idx-1), (idx+1):length(path))
                # Return error of the rule without idx-th pair
                E_minus_i = rule_metrics(path[other_idxs], X, Y)[:error]
                decay_i = (E_minus_i - E_zero) / max(E_zero, s)
                if decay_i < decay_threshold
                    # Remove the idx-th pair in the vector of decisions
                    deleteat!(path, idx)
                    E_zero = E_minus_i #rule_metrics(path, X, Y)[:error]
                end
            end
        end for path in pathset]
    end

    ########################################################################################
    # Extract rules from each tree
    ########################################################################################
    # Obtain full ruleset
    pathset = begin
        pathset = []
        for tree in forest
            tree_paths = list_paths(tree)
            append!(pathset, tree_paths)
        end
        unique(pathset) # TODO maybe also sort (which requires a definition of isless(formula1, formula2))
    end
    ########################################################################################

    ########################################################################################
    # Prune rules with respect to a dataset
    if prune_rules
        pathset = prune_pathset(pathset)
    end
    ########################################################################################

    ########################################################################################
    # Obtain the best rules
    best_rules = begin
        if method == :CBC
            # Extract antecedents
            antset = [decision.(path) for path in pathset]
            # Build the binary satisfuction matrix (m × j, with m instances and j antecedents)
            M = hcat([evaluate_antecedent(ant, X) for ant in antset]...)
            # correlation() -> function in SoleFeatures
            best_idxs = findcorrelation(M)
            #M = M[:, best_idxs]
            pathset[best_idxs]
        else
            error("Unexpected method specified: $(method)")
        end
    end
    ########################################################################################

    ########################################################################################
    # Construct a rule-based model from the set of best rules

    D = copy(X) # Copy of the original dataset
    # TODO @Michele: R and S should be Vector{Rule}; only at the end, you return DecisionList(R)
    # Ordered rule list
    R = Rule[]
    # Vector of rules left
    S = copy(best_rules)
    #TODO: SoleLogics.True
    #TODO: Fix Default Rule
    push!(S,Rule(Formula(FNode(SoleLogics.TOP)),majority_vote(Y)))

    # Rules with a frequency less than min_frequency
    S = begin
        metrics = rule_metrics.(S, X, Y)
        rules_support = [metrics[i][:support] for i in eachindex(metrics)]
        idxs_undeleted = findall(rules_support .>= min_frequency) # Undeleted rule indexes
        S[idxs_undeleted]
    end

    while true
        # Metrics update based on remaining instances
        metrics = rule_metrics.(S, D, Y)
        rules_support = [metrics[i][:support] for i in eachindex(metrics)]
        rules_error = [metrics[i][:error] for i in eachindex(metrics)]
        rules_length = [metrics[i][:length] for i in eachindex(metrics)]

        # Best rule index
        idx_best = begin
            # First: find the rule with minimum error
            idx = findall(rules_error .== min(rules_error...))
            (length(idx) == 1) && (return idx)

            # If not one, find the rule with maximum frequency
            idx_support = findall(rules_support .== max(rules_support[idx]...))
            (length(intersect!(idx, idx_support)) == 1) && (return idx)

            # If not one, find the rule with minimum length
            idx_length = findall(rules_length .== min(rules_length[idx]...))
            (length(intersect!(idx, idx_length)) == 1) && (return idx)

            # Final case: more than one rule with minimum length
            # Randomly choose a rule
            rand(idx)
        end

        # Add at the end the best rule
        # TODO: fix consequent of S[idx_best]
        push!(rules(R), path_rule(S[idx_best]))

        # Indices of the remaining instances
        idx_remaining = begin
            eval_result = evaluate_rule(S[idx_best], D, Y)
            sat_unsat = eval_result[:ant_sat]
            # Remain in D the rule that not satisfying the best rule's condition
            findall(sat_unsat .== false)
        end
        D = D[idx_remaining,:]

        if idx_best == length(S)
            #TODO: fix default field; majority_vote(Y)?
            return DecisionList(R[end-1],consequent(R[end]),(;))
        elseif size(D, 1) == 0
            return DecisionList(R,majority_vote(Y),(;))
        end

        # Delete the best rule from S
        deleteat!(S,idx_best)
        # Update of the default rule
        S[end] = Rule(Formula(FNode(SoleLogics.TOP)),majority_vote(Y[idx_remaining]))
    end

    return error("Unexpected error in extract_rules!")
end

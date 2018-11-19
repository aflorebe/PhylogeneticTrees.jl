mutable struct CodedTreeProblem
    pd::PopulationData
    bt::BinaryTree
    outgroupnode::Int
    model::JuMP.Model
    assign::JuMP.JuMPArray{JuMP.Variable}
    countedge::JuMP.JuMPDict{JuMP.Variable}
    weight::JuMP.JuMPArray{JuMP.Variable}
    f3formula
    f3err::JuMP.JuMPDict{JuMP.Variable}
end 

function CodedTreeProblem(
    pd::PopulationData, 
    bt::BinaryTree;
    binaryencoding::Bool = false,
    nlevels::Int = 1,
    solver = Gurobi.GurobiSolver())
    
    const npop = pd.npop
    const edges = bt.edges
    const leaves = getleaves(bt)
    const outgroupnode = leaves[1]
    const levels = 1:nlevels

    tree = JuMP.Model(solver=solver)
    if binaryencoding 
        @assert nlevels == 1
        JuMP.@variable(tree, assign[1:npop,getleaves(bt),levels] >= 0)
        binaryencodingconstraints(pd, bt, tree, assign)
    else 
        JuMP.@variable(tree, assign[1:npop,getleaves(bt),levels], Bin)
    end
    JuMP.@variable(tree, weight[edges] >= 0)
    JuMP.@variable(tree, weightaux[a=1:npop,b=a:npop,edges,levels,levels] >= 0)
    JuMP.@variable(tree, countedge[a=1:npop,b=a:npop,edges,levels,levels] >= 0)
    JuMP.@expression(tree, 
        f3formula[a=1:npop,b=a:npop],
        sum(weightaux[a,b,edg,l,m] for edg in edges, l in levels, m in levels)/nlevels^2)
    JuMP.@variable(tree, f3err[a=1:npop,b=a:npop])

    validtreeconstraints(pd, bt, tree, assign, outgroupnode, nlevels)
    countedgeconstraints(pd, bt, tree, assign, countedge, outgroupnode, nlevels)
    errorconstraints(pd, bt, tree, weight, weightaux, countedge, f3formula, f3err, nlevels)

    JuMP.@objective(tree, Min, 
        sum(pd.cov[a1,b1,a2,b2]*f3err[a1,b1]*f3err[a2,b2] 
            for a1 in 1:npop, a2 in 1:npop, b1 in a1:npop, b2 in a2:npop))

    CodedTreeProblem(
        pd, bt, outgroupnode, 
        tree, 
        assign, countedge, 
        weight, 
        f3formula, f3err)
end

function countedgeconstraints(
    pd::PopulationData, 
    bt::BinaryTree,
    tree::JuMP.Model, 
    assign::JuMP.JuMPArray{JuMP.Variable},
    countedge::JuMP.JuMPDict{JuMP.Variable},
    outgroupnode::Int,
    nlevels::Int)
    
    const npop = pd.npop
    const levels = 1:nlevels

    for (u,v) in bt.edges 
        if in((u,v), bt.pathedges[outgroupnode,1])
            JuMP.@constraint(tree, 
                [a=1:npop, b=a:npop, l=levels, m=levels],
                countedge[a,b,(u,v),l,m] <= 1-sum(assign[a,n,l] for n in getsubtreeleaves(bt,v)))
            JuMP.@constraint(tree,  
                [a=1:npop, b=a:npop, l=levels, m=levels],
                countedge[a,b,(u,v),l,m] <= 1-sum(assign[b,n,m] for n in getsubtreeleaves(bt,v)))
            JuMP.@constraint(tree,  
                [a=1:npop, b=a:npop, l=levels, m=levels],
                countedge[a,b,(u,v),l,m] >= 1 - sum(assign[a,n,l] + assign[b,n,m] for n in getsubtreeleaves(bt,v)))
        else
            JuMP.@constraint(tree, 
                [a=1:npop, b=a:npop, l=levels, m=levels],
                countedge[a,b,(u,v),l,m] <= sum(assign[a,n,l] for n in getsubtreeleaves(bt,v)))
            JuMP.@constraint(tree,  
                [a=1:npop, b=a:npop, l=levels, m=levels],
                countedge[a,b,(u,v),l,m] <= sum(assign[b,n,m] for n in getsubtreeleaves(bt,v)))
            JuMP.@constraint(tree,  
                [a=1:npop, b=a:npop, l=levels, m=levels],
                countedge[a,b,(u,v),l,m] >= sum(assign[a,n,l] + assign[b,n,m] for n in getsubtreeleaves(bt,v)) - 1)
        end
    end

end

function errorconstraints(pd::PopulationData, 
    bt::BinaryTree, 
    tree::JuMP.Model, 
    weight::JuMP.JuMPArray{JuMP.Variable}, 
    weightaux::JuMP.JuMPDict{JuMP.Variable}, 
    countedge::JuMP.JuMPDict{JuMP.Variable}, 
    f3formula,#::JuMP.JuMPDict{JuMP.Variable}, 
    f3err::JuMP.JuMPDict{JuMP.Variable},
    nlevels::Int)

    const npop = pd.npop 
    const bigm = maximum(pd.f3)*2
    const levels = 1:nlevels

    # set weight bilinear terms
    JuMP.@constraint(tree, 
        [a=1:npop,b=a:npop,edg=bt.edges, l=levels, m=levels],
        weightaux[a,b,edg,l,m] <= bigm*countedge[a,b,edg,l,m])
    JuMP.@constraint(tree, 
        [a=1:npop,b=a:npop,edg=bt.edges, l=levels, m=levels],
        weightaux[a,b,edg,l,m] <= weight[edg])
    JuMP.@constraint(tree, 
        [a=1:npop,b=a:npop,edg=bt.edges, l=levels, m=levels],
        weightaux[a,b,edg,l,m] >= weight[edg] + bigm*countedge[a,b,edg,l,m] - bigm)

    # set error terms
    JuMP.@constraint(tree, [a=1:npop,b=a:npop],
        f3err[a,b] >= pd.f3[a,b] - f3formula[a,b])
    JuMP.@constraint(tree, [a=1:npop,b=a:npop],
        f3err[a,b] >= f3formula[a,b] - pd.f3[a,b])

end

function Base.show(io::IO, tp::CodedTreeProblem; offset::String="")
    println(io, offset, string(typeof(tp)))
end

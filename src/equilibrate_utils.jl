#Generates the expression which is then converted into a function which generates polynomials for given parameters. Parameters not given can be given at a later stage, but parameters in the exponential must be given here.
function get_equilibration(params::Vector{Symbol},reactants::OrderedDict{Symbol,Int},f_expr::Vector{Expr})
    func_body = Expr(:block)
    #push!(func_body.args,:(@polyvar internal___polyvar___x[1:$(length(reactants))]))
    push!(func_body.args,:([]))
    foreach(poly->push!(func_body.args[1].args,recursive_replace!(poly,(reactants,:internal___polyvar___x))), deepcopy(f_expr))
    func_expr = :((;TO___BE___REMOVED=to___be___removed) -> $func_body)
    foreach(i -> push!(func_expr.args[1].args[1].args,Expr(:kw,params[i],:(internal___polyvar___p[$i]))), 1:length(params))
    deleteat!(func_expr.args[1].args[1].args,1)
    push!(func_expr.args[1].args,:internal___polyvar___x)
    return func_expr
end

#Adds information about some fixed concentration to the network. Macro for simplification
macro fixed_concentration(reaction_network,fixed_conc...)
    func_expr = Expr(:escape,:(add_fixed_concentration($reaction_network)))
    foreach(fc -> push!(func_expr.args[1].args,recursive_replace_vars!(balance_poly(fc), reaction_network)),fixed_conc)
    return func_expr
end

function balance_poly(poly::Expr)
    (poly.head != :call) && (return :($(poly.args[1])-$(poly.args[2])))
    return poly
end

function recursive_replace_vars!(expr::Any, rn::Symbol)
    if (typeof(expr) == Symbol)&&(expr!=:+)&&(expr!=:-)&&(expr!=:*)&&(expr!=:^)&&(expr!=:/)
        return :(in($(QuoteNode(expr)),$(rn).syms) ? $(rn).polyvars_vars[$(rn).syms_to_ints[$(QuoteNode(expr))]] : $(rn).polyvars_params[$(rn).params_to_ints[$(QuoteNode(expr))]])
    elseif typeof(expr) == Expr
        foreach(i -> expr.args[i] = recursive_replace_vars!(expr.args[i], rn), 1:length(expr.args))
    end
    return expr
end

#Function which does the actual work of adding the fixed concentration information. Can be called directly by inputting polynomials.
function add_fixed_concentration(reaction_network::DiffEqBase.AbstractReactionNetwork,fixed_concentrations::Polynomial...)
    check_polynomial(reaction_network)
    replaced = Set(keys(reaction_network.fixed_concentrations))
    for fc in fixed_concentrations
        vars_in_fc = []
        foreach(v -> in(v,reaction_network.polyvars_vars) && push!(vars_in_fc,reaction_network.syms[findfirst(v.==reaction_network.polyvars_vars)]), variables(fc))
        intersection = intersect(setdiff(reaction_network.syms,replaced),vars_in_fc)
        (length(intersection)==0) && (@warn "Unable to replace a polynomial"; continue;)
        next_replace = intersection[1]
        push!(replaced,next_replace)
        push!(reaction_network.fixed_concentrations,next_replace=>fc)
    end
    (reaction_network.equilibratium_polynomial==nothing) && return
    foreach(sym -> reaction_network.equilibratium_polynomial[findfirst(reaction_network.syms.==sym)] = reaction_network.fixed_concentrations[sym], keys(reaction_network.fixed_concentrations))
end

#
function fix_parameters(reaction_network::DiffEqBase.AbstractReactionNetwork;kwargs...)
    check_polynomial(reaction_network)
    reaction_network.equilibratium_polynomial = reaction_network.make_polynomial(reaction_network.polyvars_vars;kwargs...)
    !(typeof(reaction_network.equilibratium_polynomial[1])<:Polynomial) && (reaction_network.equilibratium_polynomial = map(pol->pol.num,reaction_network.equilibratium_polynomial))
    foreach(sym -> reaction_network.equilibratium_polynomial[findfirst(reaction_network.syms.==sym)] = reaction_network.fixed_concentrations[sym], keys(reaction_network.fixed_concentrations))
end

#Macro running the HC template function.
macro make_hc_template(reaction_network)
    return Expr(:escape, quote
        internal___var___p___template = randn(ComplexF64, length($(reaction_network).params))
        internal___var___f___template = DynamicPolynomials.subs.($(reaction_network).equilibratium_polynomial, Ref(internal___polyvar___p => internal___var___p___template))
        internal___var___result___template = HomotopyContinuation.solve(internal___var___f___template, report_progress=false)
        $(reaction_network).homotopy_continuation_template = (internal___var___p___template,solutions(internal___var___result___template))
    end)
end

#Solves the system once using ranomd parameters. Saves the solution as a template to be used for further solving.
function make_hc_template(reaction_network::DiffEqBase.AbstractReactionNetwork)
    check_polynomial(reaction_network)
    p_template = randn(ComplexF64, length(reaction_network.params))
    f_template = DynamicPolynomials.subs.(reaction_network.equilibratium_polynomial, Ref(reaction_network.polyvars_params => p_template))
    result_template = HomotopyContinuation.solve(f_template, report_progress=false)
    reaction_network.homotopy_continuation_template = (p_template,solutions(result_template))
end

#
function make_poly_system()
    try
        equilibratium_polynomial =
        return true
    catch
        return false
    end
end

#
function steady_states(reaction_network::DiffEqBase.AbstractReactionNetwork,params::Vector{Float64})
    (reaction_network.homotopy_continuation_template==nothing) ? make_hc_template(reaction_network) : check_polynomial(reaction_network)
    result = HomotopyContinuation.solve(reaction_network.equilibratium_polynomial, reaction_network.homotopy_continuation_template[2], parameters=reaction_network.polyvars_params, p₁=reaction_network.homotopy_continuation_template[1], p₀=params)
    filter(realsolutions(result)) do x
            all(xᵢ -> xᵢ ≥ -0.001, x)
    end
end

#
function stability(solution::Vector{Float64},reaction_network::DiffEqBase.AbstractReactionNetwork,pars::Vector{Float64})

end

function check_polynomial(reaction_network::DiffEqBase.AbstractReactionNetwork)
    (!reaction_network.is_polynomial_system) && (error("This reaction network does not correspond to a polynomial system. Some of the reaction rate must contain non polynomial terms."))
end



### Bifurcation Diagrams ###

struct bifur_path
    param::Symbol
    p_vals::Vector{Float64}
    vals::Vector{Vector{Float64}}
    jac_eigenvals::Vector{Vector{ComplexF64}}
    leng::Int64
    function bifur_path(path,param,r1,r2,reaction_network,params)
        this(param, r1 .+ ((r2-r1) .* path[1]), path[2], length(range[2]), stabilities(path[2],param,r1 .+ ((r2-r1) .* path[1]),reaction_network,params))
    end
end

function split_bifur_path!(bp,pos)
    bp1 = bifur_path(bp.param,bp.p_vals[1:pos],bp.vals[1:pos],bp.jac_eigenvals[1:pos],pos)
    bp2 = bifur_path(bp.param,bp.p_vals[pos:end],bp.vals[pos:end],bp.jac_eigenvals[pos:end],bp.leng-pos+1)
    return (bp1,bp2)
end

function split_stability(bps)
    new_bps = Vector{bifur_path}()
    for bp in bps
        stab_type = stability_type(bp.jac_eigenvals[1])
        for i = 2:bp.leng
            if stability_type(bp.jac_eigenvals[i]!=stab_type)
                (bp1,bp2) = split_bifur_path(bp,i)
                push!(new_bps,bp1)
                push!(bps,bp2)
                continue
            end
        end
    end
    return new_bps
end

function stability_type(eigenvalues)
    stab_type = 0
    (maximum(real(eigenvalues))<1e-6)&&(stab_type+=1)
    any(imag(eigenvalues).>1e-6)&&(stab_type+=2)
    return stab_type
end

function stab_color(stab_type)
    (stab_type==0) && (return :red)
    (stab_type==1) && (return :blue)
    (stab_type==2) && (return :yellow)
    (stab_type==3) && (return :green)
end

function stabilities(values,param,param_vals,reaction_network,params)
    stabs = Vector{ComplexF64}()
    Jac_temp = zeros(length(values),length(values))
    for i = 1:length(values)
        params_i = copy(params)
        params_i[reaction_network.params_to_ints[param]] = param_vals[i]
        push!(stabs,eigen(reaction_network.jac(Jac_temp,values[i],params_i,0.)).values)
    end
    return stabs
end

function bifurcations(reaction_network::DiffEqBase.AbstractReactionNetwork,params::Vector{Float64},param::Symbol,range::Tuple{Float64,Float64})
    (reaction_network.homotopy_continuation_template==nothing) ? make_hc_template(reaction_network) : check_polynomial(reaction_network)
    p1 = copy(params); p1[reaction_network.params_to_ints[param]] = range[1];
    p2 = copy(params); p2[reaction_network.params_to_ints[param]] = range[2];
    result1 = HomotopyContinuation.solve(reaction_network.equilibratium_polynomial, reaction_network.homotopy_continuation_template[2], parameters=reaction_network.polyvars_params, p₁=reaction_network.homotopy_continuation_template[1], p₀=p1)
    result2 = HomotopyContinuation.solve(reaction_network.equilibratium_polynomial, reaction_network.homotopy_continuation_template[2], parameters=reaction_network.polyvars_params, p₁=reaction_network.homotopy_continuation_template[1], p₀=p2)
    tracker1 = pathtracker_startsolutions(reaction_network.equilibratium_polynomial, parameters=reaction_network.polyvars_params, p₁=p1, p₀=p2)[1]
    tracker2 = pathtracker_startsolutions(reaction_network.equilibratium_polynomial, parameters=reaction_network.polyvars_params, p₁=p2, p₀=p1)[1]
    paths_complete = Vector{bifur_path}()
    paths_incomplete = Vector{bifur_path}()
    for result in result1
        path = track_solution(tracker1,result)
        if (currstatus(tracker1) == PathTrackerStatus.success)
            remove_sol!(result2,path[2][end])
            push!(paths_complete,path)
        else
            push!(paths_incomplete,path)
        end
    end
    for result in result2
        path = track_solution(tracker1,result)
        (currstatus(tracker1) == PathTrackerStatus.success)&&remove_path!(bifur_paths_incomplete,path[2][end])
        push!(paths,(1 .- path[1],reverse(path[2])))
    end
    append!(paths_completepaths_incomplete)
    return split_stability(bifur_path.(positive_real_projection.(path),param,range[1],range[2],reaction_network,params))
end

function remove_sol!(results,path_fin)
    for i = length(results):-1:1
        if maximum(abs.([imag.(path_fin.-results[i])..., real.(path_fin.-results[i])...]))<0.0000001
            deleteat!(results,i)
            return
        end
    end
end

function remove_path!(paths,path_fin)
    for i = length(paths):-1:1
        if maximum(abs.([imag.(path_fin.-paths[i][2][1])..., real.(path_fin.-paths[i][2][1])...]))<0.0000001
            deleteat!(results,i)
            return
        end
    end
end

function track_solution(tracker,sol)
    T = []; X = [];
    for (x,t) in iterator(tracker, sol)
        push!(T,t); push!(X,x);
    end
    return (T,X)
end

function positive_real_projection(track_result)
    T = []; X = [];
    for i = 1:length(track_result)
        if (minimum(real.(track_result[2][i]))>-0.0001)&&(maximum(imag.(track_result[2][i]))<0.0001)
            push!(T,track_result[1]); push!(X,track_result[2]);
        end
    end
    return (T,X)
end

function plot_bifs(bps)
    plot();
    plot_bifs!(bps)
end
function plot_bifs!(bps,val=1)
    for bp in bps
        color = stab_color(stability_type(bp.values[1]))
        plot(bp.p_vals,getindex.(bp.values,val),color=color,label="")
    end
    plot!()
end

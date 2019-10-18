module Pmodules

export @Parent, @P


""" Find the first undefined identifier in the lineage of another.

The given value should be an iterable of symbols, the "full name" of
an identifier. This function will find and return the first undefined
identifier in the path of the full name, or Nothing if the given identifier
is defined.
"""
function first_undefined(fullid, base_module::Module)
    search_mod = base_module

    # Make sure that the first id in fullid is the base
    # module
    if fullid[1] != nameof(base_module)
        error("Incorrect base module given to undefined search.")
    end

    for (i, modsym) = enumerate(fullid[2:end])
        if isdefined(search_mod, modsym)
            search_mod = Base.getproperty(search_mod, modsym)
        else
            return fullid[1:i + 1]
        end
    end
    return nothing
end

""" Get the object that corresponds to the given identifier.

Simply start in main and search for the given id (which is
probably a module). Kind of makes an assumption that the top of
the path has been included/imported. Generally this should only
be used to get an identifier within the current top-level package.
"""
function get_id(fullid, base_module::Module)
    search_mod = base_module

    # Make sure that the first id in fullid is the base
    # module
    if fullid[1] != nameof(base_module)
        error("Incorrect base module given to undefined search.")
    end
    
    for sym = fullid[2:end]
        # Might throw if this function was called inappropriately
        search_mod = getproperty(search_mod, sym)
    end
    return search_mod
end

""" Resolve relative identifier from the given base."""
function resolve_relative(maybe_relative, relative_base)
    # If we are absolute, just return the ident
    if maybe_relative[1] != :(.)
        return maybe_relative
    end
    # Otherwise, the number of dots minus 1 is the 
    # number of symbols taken off the end of relative base
    count_dots = 1
    for sym = maybe_relative[2:end]
        if sym == :(.)
            count_dots += 1
        end
    end

    return (relative_base[1:end-count_dots+1]..., maybe_relative[count_dots+1:end]...)
end

""" Ensure that the given identifier name will be available for import."""
function ensure_ident(ident_name, calling_module)
    mroot = Base.moduleroot(calling_module)
    # Make sure we are dealing with an internal identifier
    if ident_name[1] ∉ (nameof(mroot), :(.))
        error("Ensuring identifier of a non-internal indentifier." *
              " Ensuring $(ident_name) in $(fullname(calling_module)).")
    end

    ident_name = resolve_relative(ident_name, fullname(calling_module))

    first_undef = first_undefined(ident_name, mroot)

    if first_undef != nothing
        # We need to find a file to include
        root_dir = dirname(pathof(mroot))

        include_pen_dir = joinpath(root_dir, map(String, ident_name[2:end - 1])...)

        # Always search for bath in case of weird edge cases so we can notify the users.

        proposed_leaf = joinpath(include_pen_dir, String(ident_name[end]) * ".jl")
        proposed_parent = joinpath(include_pen_dir, String(ident_name[end]), String(ident_name[end]) * ".jl")

        is_proposed_leaf = isfile(proposed_leaf)
        is_proposed_parent = isfile(proposed_parent)

        if is_proposed_leaf && (!is_proposed_parent)
            include_dir = proposed_leaf
        elseif is_proposed_parent && (!is_proposed_leaf)
            include_dir = proposed_parent
        elseif is_proposed_leaf && is_proposed_parent
            error("Two files exist that would result in the same logical name: $(proposed_leaf) and $(proposed_parent).")
        else
            error("Could not find file that would ensure identifier $(ident_name)")
        end

        include_mod = get_id(first_undef[1:end - 1], mroot)

        Base.include(include_mod, include_dir)
    end
    # Otherwise the identifier is already defined and thus ensured.
end

""" Gives the ultimate name in the path, without the extension (if there is one)."""
finalname(path) = splitext(basename(path))[1]

""" Determine whether the given module is a parent.

Filepath should be an absolute path.
"""
function is_parent(filepath::String, mod_fullname)::Bool
    # TODO: fix this shit
    # Perform validity check
    isabspath(filepath) || error("Given path must be an absolute path.")
    # Get the relevant parts of the filepath
    directory = basename(dirname(filepath))
    filebase = splitext(basename(filepath))[1]

    # This only will occur on a top-level declaration, so the length must be 3
    # (Base, __toplevel__, module name)
    if length(mod_fullname) == 3 && mod_fullname[1:2] == fullname(Base.__toplevel__)
        # Top level Pmodule so it must be a parent
        return true
    end

    if directory == "src"
        # If the above doesn't apply and the directory is src, then the full name with
        # one entry is the parent, and the rest are leaves.
        return length(mod_fullname) == 1
    end

    # Otherwise we can use normal logic
    return directory == filebase && filebase == String(last(mod_fullname))
end

""" Define a parent module in the Pmodule system."""
macro Parent()
    # First check to see that it satisfies the parent module requirement.
    fullmod = fullname(__module__)
    filepath = String(__source__.file)

    # Make sure we are being called from a file
    if ! isfile(filepath)
        error("Pmodule called in non-file context.")
    end

    filename = finalname(filepath)
    directory = finalname(dirname(filepath))

    # Make sure we are called in a parent module.
    # TODO: More sophisticated parent detection?
    if ! is_parent(filepath, fullmod)
        error("Pmodule called in non-parent module.")
    end

    # Find all other julia files in this directory
    fulldir = dirname(filepath)
    # Use only .jl files that are not the current one
    modfiles = [finalname(fp) for fp in readdir(fulldir)
                if (endswith(fp, ".jl") && fp != basename(filepath))]

    # Ensure all identifiers before running the import statement
    return esc(Expr(:block,
        :(import Pmodules),
        [:(Pmodules.ensure_ident($(tuple(fullmod..., Symbol(mname))),
            $(__module__)))
        for mname in modfiles]...))
end


""" Support for ensuring on internal imports.
"""
macro P(ex)
    if isa(ex, Expr)
        if ex.head == :import || ex.head == :using
            # Import expression
            return esc(process_pimport(ex, __source__, __module__))
        else
            error("Unsupported expression in Pmodule system.")
        end
    else
        error("Invalid input to Pmodule macro.")
    end
end


""" Process a Pmodule import.

First determine if the desired module/modules are defined. If they are, simply import
them. If they are not, then determine the closest common ancestor, and include the
direct child of that common ancestor. If there is no common ancestor, assume that the
module is available via the usual import mechanism and import directly.

Ultimately, the import expression is used as is. It is only parsed to perform automatic
inclusion of needed files.
"""
function process_pimport(import_ex::Expr, source::LineNumberNode, module_::Module)
    # First see if the import expression is a list of imports or an import with
    # an identification specifier. If there is more than 1, we don't allow a colon part
    allow_idents = length(import_ex.args) > 1

    # Get all uniquely needed modules
    module_specs = unique([mspec for mexpr = import_ex.args for mspec = process_mexpr(mexpr, allow_idents)])

    # For each module spec, simply remove all of those that do not share a module root with the module root
    # of this module
    rootmod = Base.nameof(Base.moduleroot(module_))
    internal_mspecs = filter(t->t[1] ∈ (rootmod, :(.)), module_specs)
    # Now ensure all identifers import the import expression
    # Assume Pmodules has been imported
    return Expr(:block, :(import Pmodules), [:(Pmodules.ensure_ident($(mname), $(module_))) for mname in internal_mspecs]..., import_ex)
end

""" Process a single part of a module import expr.

The input should one of the arguments to a valid import statement.

The return is a list of module specs that outline all of the required modules
to satisfy this import expression. The module spec is a tuple of symbols that
indicate module-submodule relationship (symbols to the right are submodules
of symbols to the left).
"""
function process_mexpr(ex::Expr, allow_idents::Bool)
    if ex.head == :(.)
        # If the head is :(.), then there will only be a single tuple return
        return [tuple(ex.args...)]
    elseif ex.head == :(:)
        # Check for colon in multiple-argument import
        if allow_idents
            error("Import statement colon identifier specifier in import with multiple arguments.")
        end

        # First we get the base identifier
        base_id = tuple(ex.args[1].args...)

        # For each id on the right side of the colon, we join it with the base module
        # Note that even if the terminal identifier of a right-side part is not a module, that is
        # okay because include logic will make it so the only conflict that will occur is when
        # a name is imported from the same module that the import resides in, which is a corner
        # case that I am okay with.
        return [tuple(base_id..., rhs_id.args...) for rhs_id in ex.args[2:end]]
    else
        error("Invalid import statement.")
    end
end

end # module

module Pmodules

export @P, @ensure_ident

""" Top-level dispatch to the Pmodule system.

Supported expressions include module, import, and using.
"""
macro P(ex)
    if isa(ex, Expr)
        if ex.head == :module
            # Module expression
            modex = process_pmodule(ex, __source__, __module__)
            # make sure the module expression is evaluated in the caller scope
            return Expr(:toplevel, esc(modex))

        elseif ex.head == :import || ex.head == :using
            # Import expression
            return process_pimport(ex, __source__, __module__)
        else
            error("Unsupported expression in Pmodule system.")
        end
    else
        error("Invalid input to Pmodule macro.")
    end
end

""" Find the first undefined identifier in the lineage of another.

The given value should be an iterable of symbols, the "full name" of
an identifier. This function will find and return the first undefined
identifier in the path of the full name, or Nothing if the given identifier
is defined.
"""
function first_undefined(fullid)
    search_mod = Main
    ret = Symbol[]
    for modsym = fullid
        if isdefined(search_mod, modsym)
            push!(ret, modsym)
            search_mod = Base.getproperty(search_mod, modsym)
        else
            return ret
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
function get_id(fullid)
    searchmod = Main
    for sym = fullid
        # Might throw if this function was called inappropriately
        searchmod = getproperty(searchmod, sym)
    end
    return searchmod
end

macro ensure_ident(fullid)
    # First, make sure the given identifier is within this package.
    if Base.nameof(Base.moduleroot(__module__)) != first(fullid)
        error("ensure_ident can only be used for identifiers internal to the package.")
    end

    # Get the first undefined identifier
    first_undef = first_undefined(fullid)

    # We don't need to do anything because the ident is already available
    if first_undef === nothing
        return
    end

    # Now we need to make an include to get the identifier defined. We make
    # an assumption that the identifier is a module and is part of the Pmodule
    # system.
    
    # Get the space in which the include will be performed. We know this is
    # is defined and available
    include_space = get_id(first_undef[1:end-1])

    # Determine the path to the file to include relative to this file
    # First we need to know if we are a parent module or leaf module.
    is_pmod = is_parent(String(__source__.file))

    # We need two things: first, how far back from the current module we
    # need to go to find commonality with fullid, and, second, the rest
    # of fullid from that point
    modfull = fullname(__module__)
    common_idx = 0
    uncommon_targ = nothing
    for (i, (fid, mf)) = enumerate(zip(first_undef, modfull))
        if ! fid == mf
            uncommon_targ = fid
            break
        end
        common_idx = i
    end
    # Construct the module path.

    # Go backwards to commonality, then forwards the rest of the way
    relmodpath = Symbol[repeat(Symbol[:(..)], length(modfull) - common_idx)...,
                        Iterators.rest(first_undef, uncommon_targ)...]
    
    # Now convert the relative module path to a relative file path

    if ! is_pmod
        # All corner cases resolve nicely. If the current module is a leaf module, there
        # is always at least one ".." so we never erase relevant data. If the current target
        # module is a child of the current module, then the current module is, by definition
        # a parent module and thus this code path is not exercised.

        # We need to pop the first because leaf modules are in the same directory as their
        # siblings. 
        popfirst!(relmodpath)
    end

    # We now need to handle if the target is a parent module. There isn't really any way
    # to know except to just search the file system.
    
    # First we try leaf
    relfilepath = joinpath(map(String, relmodpath)...) * ".jl"
    # Search for the leaf file relative to the calling source file
    if ! isfile(joinpath(String(__source__.file), relfilepath))
        # If it isn't there, try as if the target is a parent module
        relfilepath = joinpath(map(String, relmodpath)..., String(relmodpath[end])) * ".jl"
    
        if ! isfile(joinpath(String(__source__.file), relfilepath))
            # Well the target include doesn't exist
            error("Could not find file to include for desired identifier.")
        end
    end
    
    # Make the include call. Note that we include it in the parent of the module we are trying to include.
    return esc(:(Base.include($include_space, $relfilepath)))
end

""" Determine whether the given module is a parent.

Filepath should be an absolute path.
"""
function is_parent(filepath::String)::Bool
    # Perform validity check
    isabspath(filepath) || error("Given path must be an absolute path.")
    # Get the relevant parts of the filepath
    directory = basename(dirname(filepath))
    filebase = splitext(basename(filepath))[1]

    return directory == "src" || directory == filebase
end

""" Pmodule declaration processing.

This should:
    1. Check if the module is a parent module or leaf module (by analyzing the file system)
    2. If it is a leaf module, just check the name matches the expected
    3. If it is a parent, add include calls for all direct children in the returned Expr
"""
function process_pmodule(module_ex::Expr, source::LineNumberNode, module_::Module)
    # Exclude baremodules
    if ! module_ex.args[1]
        error("Baremodule Pmodules are not currently supported.")
    end

    source_file = String(source.file)

    # Make sure the module/file name match
    module_sym = module_ex.args[2]
    if String(module_sym) != splitext(basename(source_file))[1]
        error("Module names must match the file name in which they are defined in the Pmodule system.")
    end

    # Determine if the module is a parent module
    is_parent_module = is_parent(String(source.file))

    # If it is a parent module, then we modify the module expression to include
    # all direct children modules.
    
    # Copy the module expression since this is not a mutating function
    modex = deepcopy(module_ex)

    # Ensure that Pmodules has been imported so we can always call @ensure_ident
    # Insert right after the module LineNumberNode
    insert!(modex.args[3].args, 2, :(import Pmodules))

    if is_parent_module
        # We need to find all the files to include
        filedir = dirname(source_file)
        dirfiles = readdir(filedir)
        modules_to_ensure = Any[]
        base_fullname = Base.fullname(module_)
        for pathname = dirfiles
            fullpath = joinpath(filedir, pathname)
            if isfile(fullpath) && fullpath != source_file
                # This is a leaf module child
                namebase, ext = splitext(pathname)
                # Only consider julia files
                if ext == ".jl"
                    push!(modules_to_ensure, tuple(base_fullname..., Symbol(namebase)))
                end
            elseif isdir(fullpath)
                # Search in the dir for <dirname>/<dirname>.jl
                searchpath = joinpath(pathname, "$pathname.jl")
                isfile(joinpath(filedir, searchpath)) &&
                    push!(modules_to_ensure, tuple(base_fullname..., Symbol(pathname)))
            end
        end

        # Add the include expressions after the Pmodule import
        for mname = modules_to_ensure
            # Assume Pmodules has been imported
            insert!(modex.args[3].args, 3, :(Pmodules.@ensure_ident $mname))
        end
    end
    return modex

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
    internal_mspecs = filter(t->t[1] == rootmod, module_specs)

    # Now ensure all identifers import the import expression
    # Assume Pmodules has been imported
    return Expr(:block, [:(Pmodules.@ensure_ident $mname) for mname in internal_mspecs]..., import_ex)
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
        if !allow_idents
            error("Import statement colon identifier specifier in import with multiple arguments.")
        end

        # First we get the base identifier
        base_id = tuple(ex.args[1]...)

        # For each id on the right side of the colon, we join it with the base module
        # Note that even if the terminal identifier of a right-side part is not a module, that is
        # okay because include logic will make it so the only conflict that will occur is when
        # a name is imported from the same module that the import resides in, which is a corner
        # case that I am okay with.
        return [tuple(base_id..., rhs_id...) for rhs_id in ex.args[2:end]]
    else
        error("Invalid import statement.")
    end
end

end # module

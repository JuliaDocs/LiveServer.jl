"""
    servedocs_callback!(args...)

Custom callback used in [`servedocs`](@ref) triggered when a file is modified.

If the file is `docs/make.jl`, the callback will check whether any new files
have subsequently been generated in the `docs/src` folder and add them to the
watched files, it will also remove any file that may have been deleted or
renamed.

If the file is either in `docs/src`, a pass of Documenter is triggered to
regenerate the documentation, subsequently the LiveServer will render the
pages produced in `docs/build`.

## Arguments

See the docs of the parent function `servedocs`.
"""
function servedocs_callback!(
            dw::SimpleWatcher,
            fp::AbstractString,
            path2makejl::AbstractString,
            literate::Union{Nothing,String},
            skip_dirs::Vector{String},
            skip_files::Vector{String},
            include_dirs::Vector{String},
            include_files::Vector{String},
            foldername::String,
            buildfoldername::String)
    # ignore things happening in the build folder (generated files etc)
    startswith(fp, joinpath(foldername, buildfoldername)) && return nothing

    # ignore files in skip_dirs and skip_files (unless the file is in include_files)
    if !(fp in include_files)
        for dir in skip_dirs
            startswith(fp, dir) && return nothing
        end
        for file in skip_files
            fp == file && return nothing
        end
    end

    # if the file that was changed is the `make.jl` file, assume that maybe
    # new files have been generated and so refresh the vector of watched files
    if fp == path2makejl
        # it's easier to start from scratch (takes negligible time)
        empty!(dw.watchedfiles)
        scan_docs!(dw, foldername, path2makejl, literate, include_dirs, include_files)
    end

    # Run a Documenter pass
    try
        Main.include(abspath(path2makejl))
        dw.status = :runnable
    catch ex
        # If there was an error, record it so that an error is displayed to the user
        dw.status = :documenter_jl_error
    end

    file_changed_callback(fp)
    return
end


"""
    scan_docs!(dw::SimpleWatcher, args...)

Scans the `docs/` folder and add all relevant files to the watched files.

## Arguments

See the docs of the parent function `servedocs`.
"""
function scan_docs!(dw::SimpleWatcher,
                    foldername::String,
                    path2makejl::String,
                    literate::Union{Nothing,String},
                    include_dirs::Vector{String},
                    include_files::Vector{String},
                    )::Nothing
    # Typical expected structure:
    #   docs
    #   ├── make.jl
    #   └── src
    #       ├── *
    #       └── *
    src = joinpath(foldername, "src")

    if !isdir(foldername) || !isdir(src)
        error("I didn't find a $foldername/ or $foldername/src/ folder.")
    end

    # watch the make.jl file as well as
    push!(dw.watchedfiles, WatchedFile(path2makejl))

    # include all files in the docs/src directory
    if isdir(foldername)
        # add all files in `docs/src` to watched files
        for (root, _, files) ∈ walkdir(joinpath(foldername, "src")), file ∈ files
            push!(dw.watchedfiles, WatchedFile(joinpath(root, file)))
        end
    end

    # include all files in user-specified include directories
    for idir in filter(isdir, include_dirs)
        for (root, _, files) in walkdir(idir), file in files
            push!(dw.watchedfiles, WatchedFile(joinpath(root, file)))
        end
    end

    # include all user-specified files
    for f in filter(isfile, include_files)
        push!(dw.watchedfiles, WatchedFile(f))
    end

    # if the user is not using Literate, return early
    literate === nothing && return

    # If the user gave a specific directory for literate files, add all the
    # files in that directory to the watched files.
    # If the user did not (literate === "") then these files are already watched.
    if !isempty(literate)
        isdir(literate) || error("I didn't find the provided literate folder $literate.")
        for (root, _, files) ∈ walkdir(literate), file ∈ files
            push!(dw.watchedfiles, WatchedFile(joinpath(root, file)))
        end
    end

    # When using Literate, each script *.jl is assumed to generate a corresponding *.md
    # file. Only the source (*.jl) file should be watched to avoid an infinite loop where
    # 1. the script is executed, generates the .md file
    # 2. the .md file is seen as modified, triggers the make.jl file
    # 3. the make.jl file executes the script (↩1)
    # So here we remove from the watchlist all files.md that have a files.jl with the same path.
    remove = Int[]
    if isempty(literate)
        # assumption is that the scripts are in `docs/src/...` and that the
        # generated markdown goes in exactly the same spot so for instance:
        #   docs
        #   └── src
        #       ├── index.jl
        #       └── index.md
        for wf ∈ dw.watchedfiles
            spath = splitext(wf.path)
            # ignore non `*.jl` files
            spath[2] == ".jl" || continue
            # if a `.jl` file is found, check if there's any corresponding `.md`
            # file and, if so, remove that file from the watched files to avoid ∞
            k = findfirst(e -> splitext(e.path) == (spath[1], ".md"), dw.watchedfiles)
            k === nothing || push!(remove, k)
        end
    else
        # assumption is that the scripts are in a specific folder and that the
        # generated markdown goes in `docs/src` with the same relative path
        # so for instance:
        #   docs
        #   ├── literate
        #   │   └── index.jl
        #   └── src
        #       └── index.md
        # the logic is otherwise the same as above.
        for (root, _, files) ∈ walkdir(literate), file ∈ files
            spath = splitext(joinpath(root, file))
            spath[2] == ".jl" || continue
            path = joinpath(foldername, "src", chopprefix(spath[1], literate))
            k = findfirst(e -> splitext(e.path) == (path, ".md"), dw.watchedfiles)
            k === nothing || push!(remove, k)
        end
    end
    deleteat!(dw.watchedfiles, remove)
    return
end


"""
    servedocs(; kwargs...)

Can be used when developing a package to run the `docs/make.jl` file from
Documenter.jl and then serve the `docs/build` folder with LiveServer.jl.
This function assumes you are in the directory `[MyPackage].jl` with a
subfolder `docs`.

## Keyword Arguments

* `verbose=false`: boolean switch to make the server print information about
                   file changes and connections.
* `literate=nothing`: see `literate_dir`.
* `literate_dir=nothing`: Path to a directory containing Literate scripts if
                          these are not simply under `docs/src`. 
                          See also the docs for information about how to
                          work with Literate.
* `skip_dir=""`: a path starting with `docs/` where modifications should not
                 trigger the generation of the docs, this is useful for instance
                 if you're using Weave and Weave generates some files in
                 `docs/src/examples` in which case you should set
                 `skip_dir=joinpath("docs","src","examples")`.
* `skip_dirs=[]`: same as `skip_dir` but for a list of such dirs. Takes
                  precedence over `skip_dir`.
* `skip_files=[]`: a vector of files that should not trigger regeneration.
* `include_dirs=[]`: extra source directories to watch
                     (in addition to `joinpath(foldername, "src")`).
* `include_files=[]`: extra source files to watch. Takes precedence over
                      `skip_dirs` so can e.g. be used to track individual
                      files in an otherwise skipped directory.
* `foldername="docs"`: specify a different path for the content.
* `buildfoldername="build"`: specify a different path for the build.
* `makejl="make.jl"`: path of the script generating the documentation relative
                      to `foldername`.
* `host="127.0.0.1"`: where the server will start.
* `port=8000`: port number.
* `launch_browser=false`: specifies whether to launch a browser at the
                          localhost URL or not.
"""
function servedocs(;
            verbose::Bool=false,
            debug::Bool=false,
            doc_env::Bool=false,
            literate::Union{Nothing,String}=nothing,
            literate_dir::Union{Nothing,String}=literate,
            skip_dir::String="",
            skip_dirs::Vector{String}=String[],
            skip_files::Vector{String}=String[],
            include_dirs::Vector{String}=String[],
            include_files::Vector{String}=String[],
            foldername::String="docs",
            buildfoldername::String="build",
            makejl::String="make.jl",
            host::String="127.0.0.1",
            port::Int=8000,
            launch_browser::Bool=false
            )::Nothing
    # skip_dirs takes precedence over skip_dir
    if isempty(skip_dirs) && !isempty(skip_dir)
        skip_dirs = [skip_dir]
    end
    push!(skip_dirs, joinpath(foldername, buildfoldername))
    skip_dirs     = abspath.(skip_dirs)
    skip_files    = abspath.(skip_files)
    include_dirs  = abspath.(include_dirs)
    include_files = abspath.(include_files)

    # literate_dir takes precedence over literate
    if isnothing(literate_dir) && !isnothing(literate)
        literate_dir = literate
    end
    if !isnothing(literate_dir)
        literate_dir = abspath(literate_dir)
    end

    path2makejl  = joinpath(foldername, makejl)

    # The file watcher is a default SimpleWatcher with a custom
    # callback
    docwatcher = SimpleWatcher()
    set_callback!(
        docwatcher,
        fp -> servedocs_callback!(
                docwatcher, abspath(fp), path2makejl,
                literate_dir,
                skip_dirs, skip_files, include_dirs, include_files,
                foldername, buildfoldername
        )
    )

    # Scan the folder and update the list of files to watch
    scan_docs!(
        docwatcher, foldername, path2makejl,
        literate_dir, include_dirs, include_files
    )

    # activate the doc environment if required
    if doc_env
        msg = "The `doc_env` keyword argument is deprecated. Configure the environment " *
            "before calling LiveServer.servedocs instead."
        Base.depwarn(msg, :servedocs)
        prev = deprecated_activate(joinpath(foldername, "Project.toml"))
    end

    # trigger a first pass of Documenter (& possibly Literate)
    Main.include(abspath(path2makejl))

    # note the `docs/build` exists here given that if we're here it means
    # the documenter pass did not error and, therefore that a docs/build
    # has been generated.
    # So we can now serve.
    serve(
        docwatcher,
        host=host,
        port=port,
        dir=joinpath(foldername, buildfoldername),
        verbose=verbose,
        debug=debug,
        launch_browser=launch_browser
    )

    # when the serve loop is interrupted, de-activate the environment
    if doc_env
        deprecated_activate(prev)
    end
    return
end

function deprecated_activate(path)
    prev = Base.ACTIVE_PROJECT[]
    Base.ACTIVE_PROJECT[] = path
    return prev
end


#
# Miscellaneous utils
#

"""
    example()

Simple function to copy an example website folder to the current working directory that can be
watched by the LiveServer to get an idea of how things work.

### Example

```julia
LiveServer.example()
cd("example")
serve()
```
"""
function example(; basedir="")
    isempty(basedir) && (basedir = pwd())
    cp(joinpath(dirname(dirname(pathof(LiveServer))), "example"), joinpath(basedir, "example"))
end

#
# Generate example repo for servedocs
#

const INDEX_MD = raw"""
    # Test
    A link to the [other page](/man/pg1/)
    """
const PG1_JL  = raw"""
    # # Test literate
    # We can include some code like so:
    f(x) = x^5
    f(5)
    """
const MAKE_JL = raw"""
    using Documenter, Literate
    src = joinpath(@__DIR__, "src")
    lit = joinpath(@__DIR__, "literate")
    for (root, _, files) ∈ walkdir(lit), file ∈ files
        splitext(file)[2] == ".jl" || continue
        ipath = joinpath(root, file)
        opath = splitdir(replace(ipath, lit=>src))[1]
        Literate.markdown(ipath, opath)
    end
    makedocs(
        sitename = "testlit",
        pages = ["Home" => "index.md",
                 "Other page" => "man/pg1.md"]
        )
    """

"""
    servedocs_literate_example(dir="servedocs_literate_example")

Generates a folder with the right structure for servedocs+literate example.
Requires Documenter and Literate.
You can then `cd` to that folder and use servedocs:

```
julia> using LiveServer, Documenter, Literate
julia> LiveServer.servedocs_literate_example()
julia> cd("servedocs_literate_example")
julia> servedocs(literate=joinpath("docs", "literate"))
```
"""
function servedocs_literate_example(dirname="servedocs_literate_example")
    isdir(dirname) && rm(dirname, recursive=true)
    mkdir(dirname)
    # folder structure
    src  = joinpath(dirname, "src")
    mkdir(src)
    write(joinpath(src, "$dirname.jl"), "module $dirname\n foo()=1\n end")
    docs = joinpath(dirname, "docs")
    mkdir(docs)
    src = joinpath(docs, "src")
    lit = joinpath(docs, "literate")
    man = joinpath(lit, "man")
    mkdir(src)
    mkdir(lit)
    mkdir(man)
    write(joinpath(src, "index.md"), INDEX_MD)
    write(joinpath(man, "pg1.jl"), PG1_JL)
    write(joinpath(docs, "make.jl"), MAKE_JL)
    return
end

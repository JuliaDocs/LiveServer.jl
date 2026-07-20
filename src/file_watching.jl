"""
    WatchedFile

Struct for a file being watched containing the path to the file as well as the
time of last modification.
"""
mutable struct WatchedFile{T<:AbstractString}
    path::T
    mtime::Float64
end

"""
    WatchedFile(f_path)

Construct a new `WatchedFile` object around a file `f_path`.
"""
WatchedFile(f_path::AbstractString) = WatchedFile(f_path, mtime(f_path))


"""
    has_changed(wf::WatchedFile)

Check if a `WatchedFile` has changed. Returns -1 if the file does not exist, 0
if it does exist but has not changed, and 1 if it has changed.
"""
function has_changed(wf::WatchedFile)::Int
    if !isfile(wf.path)
        # isfile may return false for a file
        # currently being written. Wait for 0.1s
        # then retry once more:
        sleep(0.1)
        isfile(wf.path) || return -1
    end
    return Int(mtime(wf.path) > wf.mtime)
end

"""
    set_unchanged!(wf::WatchedFile)

Set the current state of a `WatchedFile` as unchanged
"""
set_unchanged!(wf::WatchedFile) = (wf.mtime = mtime(wf.path);)

"""
    set_unchanged!(wf::WatchedFile)

Set the current state of a `WatchedFile` as deleted (if it re-appears it will
immediately be marked as changed and trigger the callback).
"""
set_deleted!(wf::WatchedFile) = (wf.mtime = -Inf;)


"""
    FileWatcher

Abstract Type for file watching objects such as [`SimpleWatcher`](@ref).
"""
abstract type FileWatcher end


"""
    SimpleWatcher([callback]; watchdirs=String[], ignore=nothing, latency=0.01) <: FileWatcher

A simple file watcher. You can specify a callback function, receiving the path
of each file that has changed as an `AbstractString`, at construction or later
by the API function [`set_callback!`](@ref).

Changes are detected natively (without polling) using
[BetterFileWatching.jl](https://github.com/JuliaPluto/BetterFileWatching.jl):
the directories in `watchdirs` are watched recursively and, whenever a
filesystem event concerns a file that was registered with [`watch_file!`](@ref),
the callback is triggered. If `watchdirs` is left empty, the content directory
(`CONTENT_DIR[]`, or the current directory) is watched when the watcher is
[`start`](@ref)ed.

- `ignore`: optional predicate on root-relative paths (always `/`-separated);
  matching paths are not watched (see BetterFileWatching).
- `latency`: coalescing window in seconds for filesystem events (see
  BetterFileWatching).
"""
mutable struct SimpleWatcher <: FileWatcher
    callback::Union{Nothing,Function}   # callback triggered upon file change
    task::Union{Nothing,Task}           # asynchronous file-watching task
    watchedfiles::Vector{WatchedFile}   # list of files whose changes trigger the callback
    watchdirs::Vector{String}           # directories watched recursively for events
    ignore::Union{Nothing,Function}     # predicate on root-relative paths to ignore
    latency::Float64                    # event coalescing window (see BetterFileWatching)
    cancelsrc::Union{Nothing,CancellationTokenSource} # used to stop the watch task
    status::Symbol                      # flag caught by server
end

function SimpleWatcher(
            callback::Union{Nothing,Function}=nothing;
            watchdirs::Vector{<:AbstractString}=String[],
            ignore::Union{Nothing,Function}=nothing,
            latency::Real=0.01,
            sleeptime=nothing, # deprecated (polling is no longer used), accepted for compat
        )
    return SimpleWatcher(
        callback,
        nothing,
        Vector{WatchedFile}(),
        collect(String, watchdirs),
        ignore,
        Float64(latency),
        nothing,
        :runnable
    )
end


"""
    handle_change!(fw::FileWatcher, path::AbstractString)

React to a filesystem event concerning the (absolute) `path`. If `path`
corresponds to a file that is being watched (i.e. was registered with
[`watch_file!`](@ref)) and its content actually changed, the callback is
triggered. The change is confirmed via the file's modification time to filter
out spurious/duplicate events.
"""
function handle_change!(fw::FileWatcher, path::AbstractString)::Nothing
    fw.callback === nothing && return nothing
    # only react to files that have explicitly been registered for watching
    i = findfirst(wf -> abspath(wf.path) == path, fw.watchedfiles)
    i === nothing && return nothing
    wf = fw.watchedfiles[i]
    state = has_changed(wf)
    if state == 1
        # file has changed, set it unchanged and trigger callback (with the
        # originally-registered path so downstream lookups keep matching)
        set_unchanged!(wf)
        fw.callback(wf.path)
    elseif state == -1
        # file has been deleted, set the mtime to -Inf so that if it re-appears
        # then it's immediately marked as changed
        set_deleted!(wf)
    end
    return nothing
end


"""
    file_watcher_task!(fw::FileWatcher)

Helper function that's spawned as an asynchronous task; it watches the
directories in `fw.watchdirs` recursively and dispatches filesystem events to
[`handle_change!`](@ref). This task is normally terminated by cancelling
`fw.cancelsrc` (see [`stop`](@ref)) and shows a warning in the presence of any
other exception.
"""
function file_watcher_task!(fw::FileWatcher)::Nothing
    try
        tok = get_token(fw.cancelsrc)
        @sync for dir in fw.watchdirs
            isdir(dir) || continue
            @spawn begin
                try
                    watch_folder(dir, tok; ignore=fw.ignore, latency=fw.latency) do event
                        for p in paths_tuple(event)
                            handle_change!(fw, p)
                        end
                    end
                catch
                    # unblock the sibling watchers so `@sync` can return
                    cancel(fw.cancelsrc)
                    rethrow()
                end
            end
        end
    catch err
        fw.status = :interrupted
        if VERBOSE[]
            @error "fw error" exception=(err, catch_backtrace())
        end
    end
    return nothing
end


"""
    set_callback!(fw::FileWatcher, callback::Function)

Set or change the callback function being executed upon a file change.
Can be "hot-swapped", i.e. while the file watcher is running.
"""
function set_callback!(fw::FileWatcher, callback::Function)::Nothing
    prev_running = stop(fw)   # returns true if was running
    fw.callback  = callback
    prev_running && start(fw) # restart if it was running before
    fw.status = :runnable
    return nothing
end


"""
    is_running(fw::FileWatcher)

Checks whether the file watcher is running.
"""
is_running(fw::FileWatcher) = (fw.task !== nothing) && !istaskdone(fw.task)


"""
    start(fw::FileWatcher)

Start the file watcher and wait to make sure the task has started.
"""
function start(fw::FileWatcher)
    is_running(fw) && return
    # if no directories were specified explicitly, watch the content directory
    # (or the current directory) recursively
    if isempty(fw.watchdirs)
        root = isempty(CONTENT_DIR[]) ? "." : CONTENT_DIR[]
        fw.watchdirs = [abspath(root)]
    end
    fw.cancelsrc = CancellationTokenSource()
    fw.status = :runnable
    fw.task = @spawn file_watcher_task!(fw)
    # wait until task runs to ensure reliable start (e.g. if `stop` called
    # right after start)
    while fw.task.state != :runnable
        sleep(0.01)
    end
    return
end


"""
    stop(fw::FileWatcher)

Stop the file watcher. The list of files being watched is preserved and new
files can still be added to the file watcher using `watch_file!`. It can be
restarted with `start`. Returns a `Bool` indicating whether the watcher was
running before `stop` was called.
"""
function stop(fw::FileWatcher)::Bool
    was_running = is_running(fw)
    if was_running
        # cancel the token so that every `watch_folder` call returns and the
        # watching task finishes
        fw.cancelsrc === nothing || cancel(fw.cancelsrc)
        # wait until sure the task is done
        while !istaskdone(fw.task)
            sleep(0.05)
        end
    end
    return was_running
end


"""
    is_watched(fw::FileWatcher, f_path::AbstractString)

Checks whether the file specified by `f_path` is being watched.
"""
function is_watched(fw::FileWatcher, f_path::AbstractString)
    return any(wf -> wf.path == f_path, fw.watchedfiles)
end


"""
    watch_file!(fw::FileWatcher, f_path::AbstractString)

Add a file to be watched for changes.
"""
function watch_file!(fw::FileWatcher, f_path::AbstractString)
    if isfile(f_path) && !is_watched(fw, f_path)
        push!(fw.watchedfiles, WatchedFile(f_path))
        if VERBOSE[]
            @info "[FileWatcher]: now watching '$f_path'"
            println()
        end
    end
end

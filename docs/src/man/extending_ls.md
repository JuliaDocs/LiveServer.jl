# Extending LiveServer

There may be circumstances where you will want the page-reloading to be triggered by your own mechanism.
As a very simple example, you may want to display your own custom messages every time a file is updated.
This page explains how to extend `SimpleWatcher <: FileWatcher` and, more generally, how to write your own `FileWatcher`.
We also explain how in some circumstances it may be easier to feed a custom `coreloopfun` to [`serve`](@ref) rather than writing a custom callback.

## Using `SimpleWatcher` with a custom callback

In most circumstances, using an instance of the `SimpleWatcher` type with your own _custom callback function_ is what you will want to do.

The `SimpleWatcher` does what you expect: it watches files for changes and triggers a function (the _callback_) when a change is detected.
The callback function takes as argument the path of the file that was modified and returns `nothing`.

The base callback function ([`LiveServer.file_changed_callback`](@ref)) does only one thing: it sends a signal to the relevant viewers to trigger page reloads.
You will typically want to re-use `file_changed_callback` or copy its code.

As an example of a custom callback, here is a simple modified callback mechanism which prints `Hello!` before using the base callback function:

```julia
custom_callback(fp::AbstractString) = (println("Hello!"); file_changed_callback(fp))
```

A more sophisticated customised callback is the one that is used in [`servedocs`](@ref) (see [`LiveServer.servedocs_callback!`](@ref)).
The callback has a different behaviour depending on which file is modified and does a few extra steps before signalling the viewers to reload appropriate pages.

## Writing your own `FileWatcher`

If you decide to write your own `FileWatcher` type, you will need to meet the API.
The easier is probably that you look at the code for [`LiveServer.SimpleWatcher`](@ref) and adapt it to your need.
Let's assume for now that you want to define a `CustomWatcher <: FileWatcher`.

### Fields

The only field that is _required_ by the rest of the code is

* `status`: a symbol that must be set to `:interrupted` upon errors in the file watching task

Likely you will want to have some (probably most) of the fields of a `SimpleWatcher` i.e.:

* `callback`: the callback function to be triggered upon an event,
* `task`: the asynchronous file watching task,
* `watchedfiles`: the vector of [`LiveServer.WatchedFile`](@ref) i.e. the paths to the file being watched as well as their time of last modification,
* `watchdirs`: the directories that are watched recursively for filesystem events; a change to a file under one of these directories triggers the callback only if that file is in `watchedfiles`,
* `ignore`: an optional predicate on root-relative paths (always `/`-separated) used to skip watching some paths,
* `latency`: the coalescing window (in seconds) for filesystem events.

Of course you can add any extra field you may want.

### Methods

Subsequently, your `CustomWatcher` may redefine some or all of the following methods (those that aren't will use the default method defined for `FileWatcher` and thus
all of its sub-types).

The methods that are _required_ by the rest of the code are

* `start(::FileWatcher)` and `stop(::FileWatcher)` to start and stop the watcher,
* `watch_file!(::FileWatcher, ::AbstractString)` to consider an additional file.

You may also want to re-define existing methods such as

* `file_watcher_task!(::FileWatcher)`: the task that watches `CustomWatcher.watchdirs` for filesystem events and triggers the callback function for modified files. This task will be referenced by the field `CustomWatcher.task`. If errors happen in this asynchronous task, the `CustomWatcher.status` should be set to `:interrupted` so that all running tasks can be stopped properly.
* `set_callback!(::FileWatcher, ::Function)`: a helper function to bind a watcher with a callback function.
* `is_running(::FileWatcher)`: a helper function to check whether `CustomWatcher.task` is done.
* `is_watched(::FileWatcher, ::AbstractString)`: check if a file is watched by the watcher.

## Using a custom `coreloopfun`

In some circumstances, your code may be using specific data structures or be such that it would not easily play well with a `FileWatcher` mechanism.
In that case, you may want to also specify a `coreloopfun` which is called continuously from within the [`serve`](@ref) main loop.

The code of [`serve`](@ref) is essentially structured as follows:

```julia
function serve(...)
    # ...
    @async HTTP.listen(...) # handles messages with the client (browser)
    # ...
    try
        counter = 1
        while true # the main loop
            # ...
            coreloopfun(counter, filewatcher)
            counter += 1
            sleep(0.1)
        end
    catch err
        # ...
    finally
        # cleanup ...
    end
    return nothing
end
```

That is, the `coreloopfun` is called roughly every 100 ms while the server is running.
By default the `coreloopfun` does nothing.

An example where this mechanism could be used is when your code handles the processing of files from one format (say markdown) to HTML. You want the `FileWatcher` to trigger browser reloads whenever new versions of these HTML files are produced. However, at the same time, you want another process to keep track of the markdown files and re-process them as they change. You can hook this second watcher into the core loop of `LiveServer` using the `coreloopfun`.
An example for this use case is [JuDoc.jl](https://github.com/tlienart/JuDoc.jl).

## How file watching works

File changes are detected natively (without polling) using
[BetterFileWatching.jl](https://github.com/JuliaPluto/BetterFileWatching.jl), which
builds on Julia's `FileWatching` stdlib (libuv on macOS/Windows, raw `inotify` on Linux)
to watch directories recursively.

Native watchers can be quite sensitive (they may report more events than just a "save"),
so `SimpleWatcher` filters the raw events: an event only triggers the callback if it
concerns a file that was explicitly registered via [`watch_file!`](@ref) _and_ the file's
modification time confirms that its contents actually changed. This keeps the "trigger on
save" behaviour while relying on the OS to notify us of changes instead of polling.

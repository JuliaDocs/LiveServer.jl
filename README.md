# Live Server for Julia

[![CI](https://github.com/JuliaDocs/LiveServer.jl/actions/workflows/ci.yml/badge.svg?branch=master&event=push)](https://github.com/JuliaDocs/LiveServer.jl/actions/workflows/ci.yml)
[![codecov](https://codecov.io/gh/JuliaDocs/LiveServer.jl/graph/badge.svg?token=m0lo2IyZ6G)](https://codecov.io/gh/JuliaDocs/LiveServer.jl)
[![docs](https://img.shields.io/badge/docs-latest%20release-blue)](https://juliadocs.github.io/LiveServer.jl/)


This is a simple and lightweight development web-server written in Julia,
based on [HTTP.jl](https://github.com/JuliaWeb/HTTP.jl).
It has live-reload capability, i.e. when modifying a file, every browser (tab)
currently displaying the corresponding page is automatically refreshed.

LiveServer is inspired from Python's [`http.server`](https://docs.python.org/3/library/http.server.html)
and Node's [`browsersync`](https://www.browsersync.io/).

## Installation

To install it in Julia ≥ 1.6, use the package manager with

```julia-repl
pkg> add LiveServer
```

### Broken pipe message

Infrequently, you _may_ see an error message in your console while using LiveServer that does not
interrupt the server and does not otherwise affect your ability to see updates in the browser.
This error message will look like

```
┌ LogLevel(1999): handle_connection handler error
│   exception =
│    IOError: write: broken pipe (EPIPE)
```

You can basically ignore this message, it's a problem with [HTTP.jl](https://github.com/JuliaWeb/HTTP.jl).

If your application depends on LiveServer and you'd like to avoid having that kind of messages being shown to your users, you can consider using [LoggingExtras.jl](https://github.com/JuliaLogging/LoggingExtras.jl) which
allows you to filter out messages based on their provenance. 

We experimented with shipping LoggingExtras in LiveServer but ended up rolling that back as it made
other applications less stable.



### Legacy notes

For Julia `< 1.6`, you can use LiveServer's version 0.9.2:

```julia-repl
pkg> add LiveServer@0.9.2
```

For Julia `[1.0, 1.3)`, you can use LiveServer's version 0.7.4:

```julia-repl
pkg> add LiveServer@0.7.4
```

### Make it a shell command

LiveServer is a small package and fast to load with one main functionality (`serve`),
it can be convenient to make it a shell command: (I'm using the name `lss` here but
you could use something else):

```
alias lss='julia -e "import LiveServer as LS; LS.serve(launch_browser=true)"'
```

you can then use `lss` in any directory to show a directory listing in your browser,
and if the directory has an `index.html` then that will be rendered in your browser.

## Usage

The main function `LiveServer` exports is `serve` which starts listening to the current
folder and makes its content available to a browser.
The following code creates an example directory and serves it:

```julia-repl
julia> using LiveServer
julia> LiveServer.example() # creates an "example/" folder with some files
julia> cd("example")
julia> serve() # starts the local server & the file watching
✓ LiveServer listening on http://localhost:8000/ ...
  (use CTRL+C to shut down)
```

Open a Browser and go to `http://localhost:8000/` to see the content being rendered;
try modifying files (e.g. `index.html`) and watch the changes being rendered immediately in the browser.

In the REPL:
```julia-repl
julia> using LiveServer
julia> serve(host="0.0.0.0", port=8001, dir=".") # starts the remote server & the file watching
✓ LiveServer listening on http://0.0.0.0:8001...
  (use CTRL+C to shut down)
```

In the terminal:
```bash
julia -e 'using LiveServer; serve(host="0.0.0.0", port=8001, dir=".")'
```

Open a browser and go to https://localhost:8001/ to see the rendered content of index.html or,
if it doesn't exist, the content of the directory.
You can set the port to a custom number.
This is similar to the [`http.server`](https://docs.python.org/3/library/http.server.html) in Python.

### Serve docs

`servedocs` is a convenience function that runs `Documenter` along with `LiveServer` to watch
your doc files for any changes and render them in your browser when modifications are detected.  

Assuming you are in `directory/to/YourPackage.jl`, that you have a `docs/` folder as
prescribed by [Documenter.jl](https://github.com/JuliaDocs/Documenter.jl) and `LiveServer`
installed in your global environment, you can run:

```julia-repl
$ julia

pkg> activate docs

julia> using YourPackage, LiveServer

julia> servedocs()
[ Info: SetupBuildDirectory: setting up build directory.
[ Info: ExpandTemplates: expanding markdown templates.
...
└ Deploying: ✘
✓ LiveServer listening on http://localhost:8000/ ...
  (use CTRL+C to shut down)
```

Open a browser and go to `http://localhost:8000/` to see your docs being rendered;
try modifying files (e.g. `docs/index.md`) and watch the changes being rendered in the browser.

To run the server with one line of code, run:

```
$ julia --project=docs -ie 'using YourPackage, LiveServer; servedocs()'
```

**Note**: this works with [Literate.jl](https://github.com/fredrikekre/Literate.jl) as well.
See [the docs](https://juliadocs.github.io/LiveServer.jl/dev/man/ls+lit/).


## DEV/Path testing

See also issue #135 and related PRs.

* `servedocs()`, navigate to literate, images should show
* `serve()` navigate manually to `docs/build/` should show, remove trailing slash in URL `docs/build` should redirect to `docs/build/`
* `serve(dir=...)` should work + when navigating to assets etc

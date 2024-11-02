module LiveServer

import Sockets, MIMEs
using Base.Filesystem
using Base.Threads: @spawn

using HTTP
using LoggingExtras

export serve, servedocs

#
# Environment variables
#

"""Script to insert on a page for live reload, see `client.html`."""
const BROWSER_RELOAD_SCRIPT = read(joinpath(@__DIR__, "client.html"), String)

"""Whether to display messages while serving or not, see [`verbose`](@ref)."""
const VERBOSE = Ref(false)

"""Whether to display debug messages while serving"""
const DEBUG = Ref(false)

"""The folder to watch, either the current one or a specified one (dir=...)."""
const CONTENT_DIR = Ref("")

"""List of files being tracked with WebSocket connections."""
const WS_VIEWERS = Dict{String,Vector{HTTP.WebSockets.WebSocket}}()

"""Keep track of whether an interruption happened while processing a websocket."""
const WS_INTERRUPT = Ref(false)


set_content_dir(d::String) = (CONTENT_DIR[] = d;)
reset_content_dir() = set_content_dir("")
set_verbose(b::Bool) = (VERBOSE[] = b;)
set_debug(b::Bool) = (DEBUG[] = b;)

reset_ws_interrupt() = (WS_INTERRUPT[] = false)

# issue https://github.com/JuliaDocs/Franklin.jl/issues/977
setverbose = set_verbose

#
# Functions
#

include("file_watching.jl")
include("server.jl")

include("utils.jl")

# CLI invocation with -m (@main) requires Julia >= 1.11
if isdefined(Base, Symbol("@main"))
    include("main.jl")
end

end # module

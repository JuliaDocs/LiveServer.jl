@testset "Server/Paths                " begin
    # requested path --> a filesystem path
    bk = pwd()
    cd(joinpath(@__DIR__, ".."))
    req = "tmp"
    @test LS.get_fs_path(req) == ("", :not_found_without_404)
    req = "/test/dummies/foofile"
    @test LS.get_fs_path(req) == ("test/dummies/foofile", :file)
    req = "/test/dummies/index.html"
    @test LS.get_fs_path(req) == ("test/dummies/index.html", :dir_with_index)
    req = "/test/dummies/r%C3%A9sum%C3%A9/"
    @test LS.get_fs_path(req) == ("test/dummies/résumé/index.html", :dir_with_index)
    req = "/test/dummies/"
    @test LS.get_fs_path(req) == ("test/dummies/index.html", :dir_with_index)
    req = "/test/dummies/?query=string"
    @test LS.get_fs_path(req) == ("test/dummies/index.html", :dir_with_index)
    cd(bk)
end

#=
NOTE: if extending these tests, please be careful. As they involve @async tasks which,
themselves, spawn async tasks, if your tests fail for some reason you will HAVE to kill
the current Julia session and restart one otherwise the tasks that haven't been killed
due to the tests not being finished properly will keep running and may clash with new
tasks that you will try to start.
=#
@testset "Server/Step-by-step testing " begin
    #
    # STEP 0: cd to dummies
    #
    bk = pwd()
    cd(dirname(dirname(pathof(LiveServer))))
    cd(joinpath("test", "dummies"))
    port = 8123

    isdir("css") && rm("css", recursive=true)
    isfile("tmp.html") && rm("tmp.html")
    isdir("404") && rm("404", recursive=true)

    write("tmp.html", "blah")
    mkdir("css")
    write("css/foo.css", "body { color: pink; }")

    #
    # STEP 1: launching the listener
    #

    # define filewatcher outside so that can follow it
    fw = LS.SimpleWatcher(LS.file_changed_callback)
    task = @spawn serve(fw; port=port)
    timedwait(() -> LS.is_running(fw), 10) # give it time to get started

    # there should be a callback associated with fw now
    @test fw.status == :runnable
    # the filewatcher should be running
    @test LS.is_running(fw)
    # it also should be empty thus far
    @test isempty(fw.watchedfiles)

    #
    # STEP 2: triggering a request
    #
    response = HTTP.get("http://localhost:$port/")
    @test response.status == 200
    # the browser script should be appended
    @test String(response.body) == replace(read("index.html", String),
                            "</body>"=>"$(LS.BROWSER_RELOAD_SCRIPT)</body>")
    hdict = Dict(response.headers)
    @test occursin("text/html", hdict["Content-Type"])
    # if one asks for something incorrect, a 404 should be returned
    response = HTTP.get("http://localhost:$port/no.html"; status_exception=false)
    @test response.status == 404
    @test occursin("404 Not Found", String(response.body))
    # test custom 404.html page
    mkdir("404"); write("404/index.html", "custom 404")
    response = HTTP.get("http://localhost:$port/no.html"; status_exception=false)
    @test response.status == 404
    @test occursin("custom 404", String(response.body))
    # if one asks for something without a </body>, it should just be appended
    response = HTTP.get("http://localhost:$port/tmp.html")
    @test response.status == 200
    @test String(response.body) == read("tmp.html", String) * LS.BROWSER_RELOAD_SCRIPT
    response = HTTP.get("http://localhost:$port/css/foo.css")
    @test String(response.body) == read("css/foo.css", String)
    @test response.status == 200

    # we asked earlier for index.html therefore that file should be followed
    @test fw.watchedfiles[1].path == "index.html"
    # also 404
    @test fw.watchedfiles[2].path == "404/index.html"
    # also tmp
    @test fw.watchedfiles[3].path == "tmp.html"
    # and the css
    @test fw.watchedfiles[4].path == "css/foo.css"

    # if we modify the file, it should trigger the callback function which should open
    # and then subsequently close a websocket. We check this happens properly by adding
    # our own sentinel websocket
    function makews()
        io = IOBuffer(UInt8[], read=true, write=true)
        return HTTP.WebSockets.WebSocket(io, () -> nothing; is_client=false)
    end
    sentinel = makews()
    LS.WS_VIEWERS["tmp.html"] = [sentinel]

    @test !sentinel.writeclosed
    write("tmp.html", "something new")
    sleep(0.5)
    # the sentinel websocket should be closed
    @test sentinel.writeclosed
    # the websockets should have been flushed
    @test isempty(LS.WS_VIEWERS["tmp.html"])

    # let's do this again with an infra file which will ping all websockets
    sentinel1 = makews()
    sentinel2 = makews()
    push!(LS.WS_VIEWERS["tmp.html"], sentinel1)
    LS.WS_VIEWERS["css/foo.css"] = [sentinel2]
    write("css/foo.css", "body { color:blue; }")
    sleep(0.5)
    # all sentinel websockets should be closed
    @test sentinel1.writeclosed
    @test sentinel2.writeclosed

    # Mimic an error when building documentation with Documenter.jl. When this
    # happens servedocs_callback!() will set the watcher status to
    # :documenter_jl_error.
    fw.status = :documenter_jl_error

    # Now any requests should give us the custom error page
    response = HTTP.get("http://localhost:$port/"; status_exception=false)
    body_str = String(response.body)
    @test response.status == 500
    @test occursin("error occurred when rebuilding", body_str)
    # And they should include the browser reload script so they automatically
    # reload when the docs build again.
    @test occursin(LS.BROWSER_RELOAD_SCRIPT, body_str)
    # Reset the watcher status for the rest of the tests
    fw.status = :runnable

    # if we remove the files, it shall stop following it
    rm("tmp.html")
    rm("css", recursive=true)
    rm("404", recursive=true)
    sleep(0.5)
    # everything is still watched (#160)
    @test length(fw.watchedfiles) == 4

    #
    # SHUTTING DOWN
    #
    # this should have interrupted the server, so it should be possible
    # to restart one on the same port (otherwise this will throw an error, already in use)
    schedule(task, InterruptException(), error=true)
    sleep(1.5) # give it time to get done
    @test istaskdone(task)
    @test begin
        server = Sockets.listen(port)
        sleep(0.1)
        close(server)
        true
    end == true

    # Check that WS_FILES is properly destroyed
    isempty(LS.WS_VIEWERS)

    cd(bk)
end

@testset "Server/ws_tracker testing   " begin
    bk = pwd()
    cd(mktempdir())
    write("test_file.html", "Hello!")

    target = "/test_file.html"
    fs_path, _ = LS.get_fs_path(target)
    @test fs_path == "test_file.html"

    function make_tracking_ws(tgt)
        io = IOBuffer(UInt8[], read=true, write=true)
        ws = HTTP.WebSockets.WebSocket(io, () -> nothing; is_client=false)
        ws.handshake_request = HTTP.Request("GET", tgt, [
            "Connection" => "upgrade",
            "Upgrade" => "websocket",
            "Sec-WebSocket-Key" => "k5zQsAMXfFlvmWIE/YCiEg==",
            "Sec-WebSocket-Version" => "13"
        ])
        return ws
    end

    ws1 = make_tracking_ws(target)
    tsk = @spawn LS.ws_tracker(ws1)
    sleep(1.0)
    # the websocket should have been added to the list
    @test LS.WS_VIEWERS[fs_path] isa Vector{HTTP.WebSockets.WebSocket}
    @test length(LS.WS_VIEWERS[fs_path]) >= 1

    # simulate a "good" closure (an event caused a write on the websocket and then closes it)
    ws = LS.WS_VIEWERS[fs_path][1]
    close(ws)
    sleep(1.0)
    @test istaskdone(tsk)
    @test !LS.WS_INTERRUPT[]

    ws2 = make_tracking_ws(target)
    tsk = @spawn LS.ws_tracker(ws2)
    sleep(1.0)

    # simulate a "bad" closure
    schedule(tsk, InterruptException(), error=true)
    sleep(5.1)
    @test istaskdone(tsk)
    @test LS.WS_INTERRUPT[]

    @test length(LS.WS_VIEWERS[fs_path]) == 2

    # cleanup
    empty!(LS.WS_VIEWERS)

    cd(bk)
end

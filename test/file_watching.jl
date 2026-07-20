# create files in a temporary dir that we can modify
const tmpdir = mktempdir()
const file1 = joinpath(tmpdir, "file1")
const file2 = joinpath(tmpdir, "file2")
write(file1, ".")
write(file2, ".")

@testset "Watcher/WatchedFile struct  " begin
    wf1 = LS.WatchedFile(file1)
    wf2 = LS.WatchedFile(file2)

    # Basic struct
    @test wf1.path == file1
    @test wf2.path == file2
    @test wf1.mtime == mtime(file1)
    @test wf2.mtime == mtime(file2)

    # Apply change and check if it's detecte
    t1 = time()
    sleep(FS_WAIT)
    write(file1, "hello")
    sleep(FS_WAIT)
    @test LS.has_changed(wf1) == 1
    @test LS.has_changed(wf2) == 0

    # Set state as unchanged
    LS.set_unchanged!(wf1)
    @test LS.has_changed(wf1) == 0
    @test wf1.mtime > t1
end

@testset "Watcher/SimpleWatcher struct" begin
    sw  = LS.SimpleWatcher()

    @test isa(sw, LS.FileWatcher)

    sw1 = LS.SimpleWatcher(identity)

    # Base constructor check
    @test sw.callback === nothing
    @test sw.task === nothing
    @test isempty(sw.watchedfiles)
    @test eltype(sw.watchedfiles) == LS.WatchedFile
    @test isempty(sw.watchdirs)
    @test sw.ignore === nothing
    @test sw.cancelsrc === nothing
    @test sw.status == :runnable

    @test sw1.callback(2) == 2 # identity function
    @test sw1.callback("blah") == "blah"
    @test isempty(sw1.watchedfiles)
    @test sw1.task === nothing

    # kwargs are honoured
    ign = rel -> false
    sw2 = LS.SimpleWatcher(identity; watchdirs=[tmpdir], ignore=ign, latency=0.02)
    @test sw2.watchdirs == [tmpdir]
    @test sw2.ignore === ign
    @test sw2.latency == 0.02
    # `sleeptime` is accepted (deprecated) for backwards compatibility
    @test LS.SimpleWatcher(identity; sleeptime=0.5) isa LS.SimpleWatcher
end

@testset "Watcher/watch  file routines" begin
    sw = LS.SimpleWatcher(identity; watchdirs=[tmpdir])

    LS.watch_file!(sw, file1)
    LS.watch_file!(sw, file2)

    @test sw.watchedfiles[1].path == file1
    @test sw.watchedfiles[2].path == file2

    # is_watched
    @test LS.is_watched(sw, file1)
    @test LS.is_watched(sw, file2)

    # is_running?
    @test !LS.is_running(sw)

    LS.start(sw)
    sleep(0.1)

    @test LS.is_running(sw)
    @test LS.stop(sw)
    @test !LS.is_running(sw)

    #
    # a real change triggers the callback with the watched path
    #
    changed = String[]
    sw = LS.SimpleWatcher(fp -> push!(changed, fp); watchdirs=[tmpdir])
    LS.watch_file!(sw, file1)
    LS.start(sw)
    sleep(0.5)      # give the native watcher time to initialise
    sleep(FS_WAIT)  # ensure the mtime will actually differ
    write(file1, "a change")
    # wait for the event to propagate
    tstart = time()
    while isempty(changed) && time() - tstart < 10
        sleep(0.1)
    end
    LS.stop(sw)
    @test file1 in changed

    #
    # modify callback to something that will eventually throw an error
    #
    sw = LS.SimpleWatcher(identity; watchdirs=[tmpdir])
    LS.watch_file!(sw, file1)
    LS.set_callback!(sw, log)
    @test sw.callback(exp(1.0)) ≈ 1.0

    LS.start(sw)
    sleep(0.5)      # give the native watcher time to initialise

    # causing a modification will generate an error because the callback
    # function will fail on a string
    cray = Crayon(foreground=:cyan, bold=true)
    println(cray, "\n⚠ Deliberately causing an error to be displayed and handled...\n")
    sleep(FS_WAIT)  # ensure the mtime will actually differ
    write(file1, "modif")
    tstart = time()
    while sw.status != :interrupted && time() - tstart < 10
        sleep(0.1)
    end
    @test sw.status == :interrupted

    #
    # deleting files
    #

    file3 = joinpath(tmpdir, "file3")
    write(file3, "hello")

    sw = LS.SimpleWatcher(identity)

    LS.watch_file!(sw, file1)
    LS.watch_file!(sw, file2)
    LS.watch_file!(sw, file3)

    @test length(sw.watchedfiles) == 3
end

using Documenter, LiveServer

makedocs(
    modules = [LiveServer],
    format = Documenter.HTML(
        # Use clean URLs, unless built as a "local" build
        prettyurls = !("local" in ARGS),
        # custom CSS
        assets = ["assets/custom.css"]
        ),
    sitename = "LiveServer.jl",
    authors  = "Jonas Asprion, Thibaut Lienart",
    pages    = [
        "Home" => "index.md",
        "Manual" => [
            "Functionalities" => "man/functionalities.md",
            "Extending LiveServer" => "man/extending_ls.md",
            "LiveServer + Literate" => "man/ls+lit.md"
            ],
        "Library" => [
            "Public"    => "lib/public.md",
            "Internals" => "lib/internals.md",
            ],
        ], # end page
)

deploydocs(
    repo = "github.com/JuliaDocs/LiveServer.jl.git"
)

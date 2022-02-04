# Select

**DEPRECATED: This repo was an experiment, but is not maintained, and the code is quite old. See https://github.com/JuliaLang/julia/issues/13763 for a longer discussion on `@select` in Julia.**

This repo is branched from https://github.com/durcan/Select.jl, which was originally a copy of [Jon Malmaud's](https://github.com/malmaud) go-inspired select macro for the Julia programming language. I have updated the repo for Julia 1.3+, multithreaded the Select macro, and hardened the code a bit.

Install this package via:
```julia
julia> Pkg.add("https://github.com/NHDaly/Select.jl")
```

The original README from [durcan/Select.jl](https://github.com/durcan/Select.jl) follows:

-----------------------------------------------------

This is copy of [Jon Malmaud's](https://github.com/malmaud) go inspired select macro for the Julia programming language. I have made a slight syntax modification, but essentially all the code is his.


A select expression is for waiting on multiple communication operations and is of the form:
```julia
@select begin
     clause1 => body1
     clause2 => body2
     _       => default_body
    end
end
```
Wait for multiple clauses simultaneously using an pattern matching syntax, taking a different action depending on which clause is available first.
A clause has three possible forms:

1. `event |> value`
  If `event` is an `AbstractChannel`, wait for a value to become available in the channel and assign `take!(event)` to `value`.
  if `event` is a `Task`, wait for the task to complete and assign `value` the return value of the task.
2. `event |< value`
  Only suppored for `AbstractChannel`s. Wait for the channel to capabity to store an element, and then call `put!(event, value)`.
3. `event`
  Calls `wait` on `event`, discarding the return value. Usable on any "waitable" events", which include channels, tasks, `Condition` objects, and processes.

If a default branch is provided, `@select` will check arbitrary choose any event which is ready and execute its body, or will execute `default_body` if none of them are.

Otherise, `@select` blocks until at least one event is ready.

For example,

```julia
channel1 = Channel()
channel2 = Channel()
task = @task ...
result = @select begin
    channel1 |> value => begin
            info("Took from channel1")
            value
        end
    channel2 <| :test => info("Put :test into channel2")
    task              => info("task finished")
end
```

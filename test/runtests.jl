using Select
using Test

function select_block_test(t1, t2, t3, t4)
    c1 = Channel{Symbol}(1)
    c2 = Channel{Int}(1)
    c3 = Channel(1)

    put!(c3,1)

    @async begin
        sleep(t1)
        put!(c1,:a)
    end

    @async begin
        sleep(t2)
        put!(c2,1)
    end

    @async begin
        sleep(t3)
        take!(c3)
    end

    task = @async begin
        sleep(t4)
        :task_done
    end

    @select begin
        c1 |> x           => "Got $x from c1"
        c2                =>  "Got a message from c2"
        c3 <| :write_test => "Wrote to c3"
        task |> z         => begin
            "Task finished with $z"
        end
    end
end

@test select_block_test(.5, 1, 1, 1) == "Got a from c1"
@test select_block_test(1, .5, 1, 1) == "Got a message from c2"
@test select_block_test(1, 1, .5, 1) == "Wrote to c3"
@test select_block_test(1, 1, 1, .5) == "Task finished with task_done"

function select_nonblock_test(test)
    c = Channel(1)
    c2 = Channel(1)
    put!(c2, 1)
    if test == :take
        put!(c, 1)
    elseif test == :put
        take!(c2)
    elseif test == :default
    end

    @select begin
        c |> x => "Got $x from c"
        c2 <| 1 => "Wrote to c2"
        _ => "Default case"
    end
end

@test select_nonblock_test(:take) == "Got 1 from c"
@test select_nonblock_test(:put) == "Wrote to c2"
@test select_nonblock_test(:default) == "Default case"

@testset "self-references" begin
    # Test multiple times because the deadlock was only triggered if Task 1 is run before
    # Task 2 or Task 3. Running it multiple times will hopefully cover all the cases.
    for _ in 1:10
        # Test that the two clauses in `@select` can't trigger eachother (Here, the problem
        # would be if Task 1 puts into ch, then Task 2 sees Task 1 waiting, and thinks ch is
        # ready to take! and attempts to incorrectly proceed w/ the take!.) Instead, this should
        # timeout, since no one else is putting or taking on `ch`.
        ch = Channel()
        @test @select(begin
            ch <| "hi"          => "put"
            # This take!(ch) should not be triggered by the put
            ch |> x             => "take! |> $x"
            # This wait(ch) should also not be triggered by the put
            ch                  => "waiting on ch"
            @async(sleep(0.3))  => "timeout"
        end) == "timeout"
    end
end

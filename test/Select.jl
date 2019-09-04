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

@testset "@select blocking" begin
    @test select_block_test(.5, 1, 1, 1) == "Got a from c1"
    @test select_block_test(1, .5, 1, 1) == "Got a message from c2"
    @test select_block_test(1, 1, .5, 1) == "Wrote to c3"
    @test select_block_test(1, 1, 1, .5) == "Task finished with task_done"
end

@testset "@select blocking, already ready" begin
    ch = Channel(1)
    put!(ch, 1)
    @test (@select begin
        ch |> x             => x
        @async(sleep(0.3))  => "timeout"
    end) == 1

    # Can immediately put into a buffered channel
    ch = Channel(1)
    @test (@select begin
        ch <| 1             => take!(ch)
        @async(sleep(0.3))  => "timeout"
    end) == 1
end

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

@testset "@select non-blocking" begin
    @test select_nonblock_test(:take) == "Got 1 from c"
    @test select_nonblock_test(:put) == "Wrote to c2"
    @test select_nonblock_test(:default) == "Default case"
end

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

# Other waitable things
# Conditions
    # Note that we may not support Base.Condition() because it cannot be used in multithreaded code.
    ## Simple condition test: wait until a condition is notified
    #c = Condition()
    #@async while notify(c) != 1 sleep(0.5) end
    #@test @select(begin
    #    c => "c"
    #end) == "c"

@sync begin
    c = Threads.Condition()
    t = @async begin
        success = false
        while true
            lock(c)
            success = notify(c) > 0
            unlock(c)
            if success break; end
            sleep(0.5)
        end
    end
    lock(c)
    @test @select(begin
        c => (unlock(c); "c")
    end) == "c"
end

# Multiple waiters
@sync begin
    coordinator = Channel()

    c1 = Threads.Condition()
    c2 = Threads.Condition()

    wait_on_conds() = begin
        lock(c1)
        lock(c2)
        put!(coordinator, 0)
        @select begin
            c1  => begin
                put!(coordinator, 0)
                unlock(c2); unlock(c1);
            end
            c2  => begin
                put!(coordinator, 0)
                unlock(c2); unlock(c1);
            end
        end
    end
    t1 = @async wait_on_conds()
    t2 = @async wait_on_conds()

    take!(coordinator); take!(coordinator)  # Wait for both tasks to start waiting

    # Now, everyone is waiting, so notifying c1 will wake up _both_ select tasks (and kill both c2 siblings)
    lock(c1)
    @test notify(c1) == 2
    unlock(c1)
    yield()
    yield()

    take!(coordinator); take!(coordinator)  # Wait for both tasks to finish running

    # Both select tasks will have killed their sibling clauses, so no one is listening on c2
    lock(c2)
    @test notify(c2) == 0
    unlock(c2)
end

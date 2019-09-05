module Select

using Nullables

export @select

# =========================================================================================
# Custom concurrency primitives needed to support `@select`
# ------------------

function isready_put(c::Channel, sibling_tasks)
    # TODO: To fix the circular dependency, I think it might be enough to just add a check
    # here that there is at least one ready task that _isn't_ one of our siblings! We can
    # take another argument to this function, which is the list of tasks, and cross-reference it?
    return if Base.isbuffered(c)
        length(c.data) != c.sz_max
    else
        # TODO: No this isn't enough. I need to do it for the _wait_ function, not the wait_put. :'(
        #@info sibling_tasks
        #@info "isready_put:" (!isempty(c.cond_take.waitq))#, collect(c.cond_take.waitq))
        !isempty(c.cond_take.waitq) && any(t->!in(t, sibling_tasks), c.cond_take.waitq)
    end
end

function wait_put(c::Channel, sibling_tasks)
    #isready_put(c, sibling_tasks) && return
    # TODO: Is this sufficiently thread-safe?
    lock(c)
    try
        while !isready_put(c, sibling_tasks)
            Base.check_channel_state(c)
            wait(c.cond_put)  # Can be cancelled while waiting here...
        end
    finally
        unlock(c)
    end
    nothing
end

isready_wait_nosibs(c::Channel, sibling_tasks) = n_avail_nosibs(c, sibling_tasks) > 0
function n_avail_nosibs(c::Channel, sibling_tasks)
    if Base.isbuffered(c)
        length(c.data)
    else
        #@info "isready_wait_nosibs:" (isempty(c.cond_put.waitq), collect(c.cond_put.waitq))
        length(filter(t->0==count(x->x==t, sibling_tasks), collect(c.cond_put.waitq)))
    end
end
function wait_nosibs(c::Channel, sibling_tasks)
    # I don't understand why its okay to access this outside the lock...?
    #isready_wait_nosibs(c, sibling_tasks) && return
    lock(c)
    try
        while !isready_wait_nosibs(c, sibling_tasks)
            Base.check_channel_state(c)
            wait(c.cond_wait)
        end
    finally
        unlock(c)
    end
    nothing
end

wait_select(c::Channel, parent_task, sibling_tasks) = wait_nosibs(c, sibling_tasks)
wait_select(c::Base.GenericCondition, parent_task, sibling_tasks) = wait_from_parent(c, parent_task)
wait_select(x, parent_task, sibling_tasks) = wait(x)

# ---- Conditions ---------
assert_parent_haslock(c::Base.GenericCondition, parent_task) = assert_parent_haslock(c.lock, parent_task)
assert_parent_haslock(l::ReentrantLock, parent_task) =
    (islocked(l) && l.locked_by === parent_task) ? nothing : Base.concurrency_violation()
assert_parent_haslock(l::Base.AlwaysLockedST, parent_task) =
    (islocked(l) && l.ownertid === parent_task) ? nothing : Base.concurrency_violation()

function wait_from_parent(c::Base.GenericCondition, parent_task)
    ct = current_task()
    # Note that the parent task is guaranteed to be blocking on us, so this is okay.
    assert_parent_haslock(c, parent_task)
    push!(c.waitq, ct)
    token = unlockall_from_parent(c.lock, parent_task)
    try
        return wait()
    catch
        ct.queue === nothing || Base.list_deletefirst!(ct.queue, ct)
        rethrow()
    finally
        # Note that now _this task_ gets the lock, so we can execute the remaining body w/ the lock
        Base.relockall(c.lock, token)
        # eww, manually re-assign the parent to own this lock
        c.lock.locked_by = parent_task
    end
end

function unlockall_from_parent(rl::ReentrantLock, parent_task)
    n = rl.reentrancy_cnt
    rl.locked_by === parent_task || error("unlock from wrong thread")
    n == 0 && error("unlock count must match lock count")
    lock(rl.cond_wait)
    rl.reentrancy_cnt = 0
    rl.locked_by = nothing
    if !isempty(rl.cond_wait.waitq)
        try
            notify(rl.cond_wait)
        catch
            unlock(rl.cond_wait)
            rethrow()
        end
    end
    unlock(rl.cond_wait)
    return n
end


# =========================================================================================


## Implementation of 'select' mechanism to block on the disjunction of
## of 'waitable' objects.

@enum SelectClauseKind SelectPut SelectTake SelectDefault

# Represents a single parsed select "clause" of a @select macro call.
# eg, the (channel |> value) part of
# @select if channel |> value
#    println(value)
# ...
# end
struct SelectClause{ChannelT, ValueT}
    kind::SelectClauseKind
    channel::Nullable{ChannelT}
    value::Nullable{ValueT}
end

const select_take_symbol = :|>
const select_put_symbol = :<|

#  A 'structured' select clause is one of the form "channel|>val" or
#  "channel<|val". All other clauses are considered "non-structured", meaning
#  the entire clause is assumed to be an expression that evaluates to a
#  conditional to which "_take!" will be applied.
is_structured_select_clause(clause::Expr) =
    clause.head == :call &&
    length(clause.args) == 3 &&
    clause.args[1] ∈ (select_take_symbol, select_put_symbol)

is_structured_select_clause(clause) = false

function parse_select_clause(clause)
    if is_structured_select_clause(clause)
        if clause.args[1] == select_take_symbol
            SelectClause(SelectTake, Nullable(clause.args[2]), Nullable(clause.args[3]))
        elseif clause.args[1] == select_put_symbol
            SelectClause(SelectPut, Nullable(clause.args[2]), Nullable(clause.args[3]))
        end
    else
        # Assume this is a 'take' clause whose return value isn't wanted.
        # To simplify the rest of the code to not have to deal with this special case,
        # the return value is assigned to a throw-away gensym.
        SelectClause(SelectTake, Nullable(clause), Nullable(gensym()))
    end
end

"""
`@select`
A select expression of the form:
```julia
@select begin
     clause1 => body1
     clause2 => body2
     _       => default_body
    end
end
```
Wait for multiple clauses simultaneously using a pattern matching syntax, taking a different action depending on which clause is available first.
A clause has three possible forms:
1) `event |> value`
If `event` is an `AbstractChannel`, wait for a value to become available in the channel and assign `take!(event)` to `value`.
if `event` is a `Task`, wait for the task to complete and assign `value` the return value of the task.
2) `event |< value`
Only suppored for `AbstractChannel`s. Wait for the channel to capabity to store an element, and then call `put!(event, value)`.
3) `event`
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
"""
macro select(expr)
    clauses = Tuple{SelectClause, Any}[]
    # @select can operate in blocking or nonblocking mode, determined by whether
    # an 'else' clause is present in the @select body (in which case it will be
    # nonblocking).
    mode = :blocking
    for se in expr.args
        # skip line nodes
        isa(se, Expr) || continue
        # grab all the pairs
        if se.head == :call && se.args[1] == :(=>)
            if se.args[2] != :_
                push!(clauses, (parse_select_clause(se.args[2]), se.args[3]))
            else
                # The defaule case (_). If present, the select
                # statement is considered non-blocking and will return this
                # section if none of the other conditions are immediately available.
                push!(clauses, (SelectClause(SelectDefault, Nullable(), Nullable()), se.args[3]))
                mode = :nonblocking
            end
        elseif se.head != :block && se.head != :line
            # if we run into an expression that is not a block. line or pair throw an error
            throw(ErrorException("Selection expressions must be Pairs. Found: $(se.head)"))
        end
    end
    if mode == :nonblocking
        _select_nonblock_macro(clauses)
    else
        _select_block_macro(clauses)
    end
end
# These defintions allow for any condition-like object to be used
# with select.
# @select if x |> value  ... will ultimately insert an expression value=_take!(x).
_take!(c::AbstractChannel) = take!(c)
_take!(x) = fetch(x)
# @select if x <| value .... will ultimately inset value=put!(x), which currently
# is only meanginful for channels and so no underscore varirant is used here.
# These are used with the non-blocking variant of select, which will
# only work with channels and tasks. Arbitrary conditionals can't be supported
# since "wait" is level-triggered.
_isready(c::AbstractChannel) = isready(c)
_isready(t::Task) = istaskdone(t)

_wait_condition(c::AbstractChannel) = c.cond_wait
_wait_condition(x) = x

# helper function to place the default case in the proper position
function set_default_first!(clauses)
    default_pos = findall(clauses) do x
        clause, body = x
        clause.kind == SelectDefault
    end
    l = length(default_pos)
    l == 0 && return # bail out if there is no default case
    l  > 1 && throw(ErrorException("Select takes at most one default case. Found: $l"))
    # swap elements to sure make SelectDefault comes first
    clauses[1], clauses[default_pos[1]] = clauses[default_pos[1]], clauses[1]
    clauses
end

function _select_nonblock_macro(clauses)
    set_default_first!(clauses)
    branches = Expr(:block)
    for (clause, body) in clauses
        branch =
        if clause.kind == SelectPut
            channel_var = gensym("channel")
            channel_assignment_expr = :($channel_var = $(clause.channel|>get|>esc))
            :(if ($channel_assignment_expr; isready_put($channel_var, []))
                put!($channel_var, $(clause.value|>get|>esc))
                $(esc(body))
            end)
        elseif clause.kind == SelectTake
            channel_var = gensym("channel")
            channel_assignment_expr = :($channel_var = $(clause.channel|>get|>esc))
            :(if ($channel_assignment_expr; _isready($channel_var))
                $(clause.value|>get|>esc) = _take!($channel_var)
                $(esc(body))
            end)
        elseif clause.kind == SelectDefault
            :($(esc(body)))
        end

        # the next two lines build an if / elseif chain from the bottom up
        push!(branch.args, branches)
        branches = branch
    end
    :($branches)
end

# The strategy for blocking select statements is to create a set of "rival"
# tasks, one per condition. When a rival "wins" by having its conditional be
# the first available, it sends a special interrupt to its rivals to kill them.
# The interrupt includes the task where control should be resumed
# once the rival has shut itself down.
struct SelectInterrupt <: Exception
    parent::Task
end
# Kill all tasks in "tasks" besides  a given task. Used for killing the rivals
# of the winning waiting task.
function select_kill_rivals(tasks, myidx)
    #@info myidx
    for (taskidx, task) in enumerate(tasks)
        taskidx == myidx && continue
        #@info taskidx, task
        #if task.state == :waiting || task.state == :queued
            # Rival is blocked waiting for its channel; send it a message that it's
            # lost the race.
            Base.schedule(task, SelectInterrupt(current_task()), error=true)
        # TODO: Is this still a legit optimization?:
        # elseif task.state==:queued
        #     # Rival hasn't starting running yet and so hasn't blocked or set up
        #     # a try-catch block to listen for SelectInterrupt.
        #     # Just delete it from the workqueue.
        #     queueidx = findfirst(Base.Workqueue.==task)
        #     deleteat!(Base.Workqueue, queueidx)
        # end
    end
    #@info "done killing"
end
function _select_block_macro(clauses)
    branches = Expr(:block)
    body_branches = Expr(:block)
    clause_lock = gensym("clause_lock")
    lock_assignment_expr = :($clause_lock = Base.ReentrantLock())
    for (i, (clause, body)) in enumerate(clauses)
        channel_var = gensym("channel")
        value_var = clause.value|>get|>esc
        channel_declaration_expr = :(local $channel_var)
        channel_assignment_expr = :($channel_var = $(clause.channel|>get|>esc))
        if clause.kind == SelectPut
            isready_func = isready_put
            wait_for_channel =  :(wait_put($channel_var, tasks))
            mutate_channel =  :(put!($channel_var, $value_var))
            bind_variable = :(nothing)
        elseif clause.kind == SelectTake
            isready_func = _isready
            wait_for_channel =  :(wait_select($channel_var, maintask, tasks))
            mutate_channel =  :(_take!($channel_var))
            bind_variable = :($value_var = branch_val)
        end
        branch = quote
            tasks[$i] = @async begin
                $channel_declaration_expr
                try  # Listen for genuine errors to throw to the main task
                    $channel_assignment_expr

                    # ---- Begin the actual `wait_and_select` algorithm ----
                    # TODO: Is this sufficiently thread-safe?
                    # Listen for SelectInterrupt messages so we can shutdown
                    # if a rival's channel unblocks first.
                    try
                        #@info "Task $($i) about to wait"
                        $wait_for_channel

                        # TODO: Because of this gap, where no locks are held, it's possible
                        # that multiple tasks can be woken-up due to a `put!` or `take!` on
                        # a channel they were waiting for. Only once will proceed in this
                        # @select, but a channel running _outside this macro_ may yet proceed
                        # and cause a problem.. I think this is bad. Fix this (probably) by
                        # returning the lock to unlock from `wait_for_channel`.

                        # NOTE: This is _not a deadock_ because there is a global ordering
                        # to the locks: we _ALWAYS_ wait on the channel before waiting on
                        # the clause_lock. This invariant must not be violated.
                        #@info "Task $($i) about to lock"
                        lock($clause_lock)
                        # We got the lock, so run this task to completion.
                        try
                            #@info "Task $($i): got lock"
                            # This block is atomic, so it _shouldn't_ matter whether we kill
                            # rivals first or mutate_channel first. It only matters if one
                            # case is accidentally synchronizing w/ another case, which
                            # should be specifically prohibited (somehow).
                            # For now, I'm killing rivals first so that at least we'll get
                            # an exception, rather than a deadlock, if we end up waiting on
                            # our rival, sibling cases.
                            #@info "Task $($i): killing rivals"
                            select_kill_rivals(tasks, $i)

                            #@info "Task $($i): mutating"
                            event_val = $mutate_channel
                            #@info "Got event_val: $event_val"
                            put!(winner_ch, ($i, event_val))
                        finally
                            #@info "Task $($i)) unlock"
                            unlock($clause_lock)
                        end
                    catch err
                        if isa(err, SelectInterrupt)
                            #@info "CAUGHT SelectInterrupt: $err"
                            #yieldto(err.parent)  # TODO: is this still a thing we should do?
                            return
                        else
                            rethrow()
                        end
                    end
                catch err
                    Base.throwto(maintask, err)
                end
            end # if
        end # for
        push!(branches.args, branch)

        body_branch = :(if branch_id == $i; $bind_variable; $(esc(body)); end)
        # the next two lines build an if / elseif chain from the bottom up
        push!(body_branch.args, body_branches)
        body_branches = body_branch
    end
    quote
        winner_ch = Channel(1)
        tasks = Array{Task}(undef, $(length(clauses)))
        maintask = current_task()
        $lock_assignment_expr
        $branches # set up competing tasks
        (branch_id, branch_val) = take!(winner_ch) # get the id of the winning task
        $body_branches # execute the winning block in the original lexical context
    end
end
# The following methods are the functional (as opposed to macro) forms of
# the select statement.
function _select_nonblock(clauses)
    for (i, clause) in enumerate(clauses)
        if clause[1] == :put
            if isready_put(clause[2], [])
                return (i, put!(clause[2], clause[3]))
            end
        elseif clause[1] == :take
            if _isready(clause[2])
                return (i, _take!(clause[2]))
            end
        else
            error("Invalid select clause: $clause")
        end
    end
    return (0, nothing)
end
function _select_block(clauses)
    winner_ch = Channel{Tuple{Int, Any}}(1)
    tasks = Array{Task}(undef, length(clauses))
    maintask = current_task()
    for (i, clause) in enumerate(clauses)
        tasks[i] = Threads.@spawn begin
            try
                try
                    if clause[1] == :put
                        wait_put(clause[2], tasks)
                    elseif clause[1] ==  :take
                        wait_select(clause[2], maintask, tasks)
                    end
                catch err
                    if isa(err, SelectInterrupt)
                        yieldto(err.parent)
                        return
                    else
                        rethrow()
                    end
                end
                select_kill_rivals(tasks, i)
                if clause[1] == :put
                    ret = put!(clause[2], clause[3])
                elseif clause[1] == :take
                    ret = _take!(clause[2])
                end
                put!(winner_ch, (i, ret))
            catch err
                Base.throwto(maintask, err)
            end
        end
    end
    take!(winner_ch)
end
"""
`select(clauses[, block=true]) -> (clause_index, clause_value)`

Functional form of the `@select` macro, intended to be used when the set of clauses is dynamic. In general, this method will be less performant than the macro variant.

Clauses are specified as an array of tuples. Each tuple is expected to have 2 or 3 elements, as follows:

1) The clause type (`:take` or `:put`)
2) The waitable object
3) If the clause type is `:put`, the value to insert into the object.

If `block` is `true` (the default), wait for at least one clause to be satisfied and return a tuple whose first elmement is the index of the clause which unblocked first and whose whose second element is the value of the clause (see the manual on `select` for the meaning of clause value).

Otherwise, an arbitrary available clause will be executed, or a return value of `(0, nothing)` will be returned  immediately if no clause is available.
"""
function select(clauses, block=true)
    if block
        _select_block(clauses)
    else
        _select_nonblock(clauses)
    end
end
# package code goes here

end # module

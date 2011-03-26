/**
$(D std._parallelism) implements high-level primitives for SMP _parallelism.
These include parallel foreach, parallel reduce, parallel eager map, pipelining
and future/promise _parallelism.  $(D std._parallelism) is recommended when the
same operation is to be executed in parallel on different data, or when a
function is to be executed in a background thread and its result returned to a
well-defined main thread.  For communication between arbitrary threads, see
$(D std.concurrency).

$(D std._parallelism) is based on the concept of a $(D Task).  A $(D Task) is an
object that represents the fundamental unit of work in this library and may be
executed in parallel with any other $(D Task).  Using $(D Task)
directly allows programming with a future/promise paradigm.  All other
supported _parallelism paradigms (parallel foreach, map, reduce, pipelining)
represent an additional level of abstraction over $(D Task).  They
automatically create one or more $(D Task) objects, or closely related types
that are conceptually identical but not part of the public API.

After creation, a $(D Task) may be executed in a new thread, or submitted
to a $(D TaskPool) for execution.  A $(D TaskPool) encapsulates a task queue
and its worker threads.  Its purpose is to efficiently map a large
number of $(D Task)s onto a smaller number of threads.  A task queue is a
FIFO queue of $(D Task) objects that have been submitted to the
$(D TaskPool) and are awaiting execution.  A worker thread is a thread that
is associated with exactly one task queue.  It executes the $(D Task) at the
front of its queue when the queue has work available, or sleeps when
no work is available.  Each task queue is associated with zero or
more worker threads.  If the result of a $(D Task) is needed before execution
by a worker thread has begun, the $(D Task) can be removed from the task queue
and executed immediately in the thread where the result is needed.

Warning:  Unless marked as $(D @trusted) or $(D @safe), artifacts in
          this module allow implicit data sharing between threads and cannot
          guarantee that client code is free from low level data races.

Synopsis:

---
import std.algorithm, std.parallelism, std.range;

void main() {
    // Parallel reduce can be combined with std.algorithm.map to interesting
    // effect.  The following example (thanks to Russel Winder) calculates
    // pi by quadrature using std.algorithm.map and TaskPool.reduce.
    // getTerm is evaluated in parallel as needed by TaskPool.reduce.
    //
    // Timings on an Athlon 64 X2 dual core machine:
    //
    // TaskPool.reduce:       12.170 s
    // std.algorithm.reduce:  24.065 s

    immutable n = 1_000_000_000;
    immutable delta = 1.0 / n;

    real getTerm(int i) {
        immutable x = ( i - 0.5 ) * delta;
        return delta / ( 1.0 + x * x ) ;
    }

    immutable pi = 4.0 * taskPool.reduce!"a + b"(
        std.algorithm.map!getTerm(iota(n))
    );
}
---

Author:  David Simcha
Copyright:  Copyright (c) 2009-2011, David Simcha.
License:    $(WEB boost.org/LICENSE_1_0.txt, Boost License 1.0)
*/
module std.parallelism;

import core.thread, core.cpuid, std.algorithm, std.range, std.c.stdlib,
    std.stdio, std.exception, std.functional, std.conv, std.math, core.memory,
    std.traits, std.typetuple, core.stdc.string, std.typecons;

import core.sync.condition, core.sync.mutex, core.atomic;

// Workaround for bug 3753.
version(Posix) {
    // Can't use alloca() because it can't be used with exception handling.
    // Use the GC instead even though it's slightly less efficient.
    void* alloca(size_t nBytes) {
        return GC.malloc(nBytes);
    }
} else {
    // Can really use alloca().
    import core.stdc.stdlib : alloca;
}

version(Windows) {
    // BUGS:  Only works on Windows 2000 and above.

    import core.sys.windows.windows;

    struct SYSTEM_INFO {
      union {
        DWORD  dwOemId;
        struct {
          WORD wProcessorArchitecture;
          WORD wReserved;
        };
      };
      DWORD     dwPageSize;
      LPVOID    lpMinimumApplicationAddress;
      LPVOID    lpMaximumApplicationAddress;
      LPVOID    dwActiveProcessorMask;
      DWORD     dwNumberOfProcessors;
      DWORD     dwProcessorType;
      DWORD     dwAllocationGranularity;
      WORD      wProcessorLevel;
      WORD      wProcessorRevision;
    }

    private extern(Windows) void GetSystemInfo(void*);

    shared static this() {
        SYSTEM_INFO si;
        GetSystemInfo(&si);
        totalCPUs = max(1, cast(uint) si.dwNumberOfProcessors);
    }

} else version(linux) {
    import core.sys.posix.unistd;

    shared static this() {
        totalCPUs = cast(uint) sysconf(_SC_NPROCESSORS_ONLN );
    }
} else version(OSX) {
    extern(C) int sysctlbyname(
        const char *, void *, size_t *, void *, size_t
    );

    shared static this() {
        uint ans;
        size_t len = uint.sizeof;
        sysctlbyname("machdep.cpu.core_count\0".ptr, &ans, &len, null, 0);
        osReportedNcpu = ans;
    }

} else {
    static assert(0, "Don't know how to get N CPUs on this OS.");
}

/* Atomics code.  These just forward to core.atomic, but are written like this
   for two reasons:

   1.  They used to actually contain ASM code and I don' want to have to change
       to directly calling core.atomic in a zillion different places.

   2.  core.atomic has some misc. issues that make my use cases difficult
       without wrapping it.  If I didn't wrap it, casts would be required
       basically everywhere.
*/
private void atomicSetUbyte(ref ubyte stuff, ubyte newVal) {
    core.atomic.cas(cast(shared) &stuff, stuff, newVal);
}

// Cut and pasted from core.atomic.  See Bug 4760.
version(D_InlineAsm_X86) {
    private ubyte atomicReadUbyte(ref ubyte val) {
        asm {
            mov DL, 0;
            mov AL, 0;
            mov ECX, val;
            lock; // lock always needed to make this op atomic
            cmpxchg [ECX], DL;
        }
    }
} else version(D_InlineAsm_X86_64) {
    private ubyte atomicReadUbyte(ref ubyte val) {
        asm {
            mov DL, 0;
            mov AL, 0;
            mov RCX, val;
            lock; // lock always needed to make this op atomic
            cmpxchg [RCX], DL;
        }
    }
}

// This gets rid of the need for a lot of annoying casts in other parts of the
// code, when enums are involved.
private bool atomicCasUbyte(ref ubyte stuff, ubyte testVal, ubyte newVal) {
    return core.atomic.cas(cast(shared) &stuff, testVal, newVal);
}

// TODO:  Put something more efficient here, or lobby for it to be put in
// core.atomic.  This should really just use lock; inc; on x86.  This function
// is not called frequently, though, so it might not matter in practice.
private void atomicIncUint(ref uint num) {
    atomicOp!"+="(num, 1U);
}

//-----------------------------------------------------------------------------


/*--------------------- Generic helper functions, etc.------------------------*/
private template MapType(R, functions...) {
    static if(functions.length == 0) {
        alias typeof(unaryFun!(functions[0])(ElementType!(R).init)) MapType;
    } else {
        alias typeof(adjoin!(staticMap!(unaryFun, functions))
            (ElementType!(R).init)) MapType;
    }
}

private template ReduceType(alias fun, R, E) {
    alias typeof(binaryFun!(fun)(E.init, ElementType!(R).init)) ReduceType;
}

private template noUnsharedAliasing(T) {
    enum bool noUnsharedAliasing = !hasUnsharedAliasing!T;
}

// This template tests whether a function may be executed in parallel from
// @safe code via Task.executeInNewThread().  There is an additional
// requirement for executing it via a TaskPool.  (See isSafeReturn).
private template isSafeTask(F) {
    enum bool isSafeTask =
        ((functionAttributes!(F) & FunctionAttribute.SAFE) ||
        (functionAttributes!(F) & FunctionAttribute.TRUSTED)) &&
        !(functionAttributes!F & FunctionAttribute.REF) &&
        (isFunctionPointer!F || !hasUnsharedAliasing!F) &&
        allSatisfy!(noUnsharedAliasing, ParameterTypeTuple!F);
}

unittest {
    alias void function() @safe F1;
    alias void function() F2;
    alias void function(uint, string) @trusted F3;
    alias void function(uint, char[]) F4;

    static assert(isSafeTask!(F1));
    static assert(!isSafeTask!(F2));
    static assert(isSafeTask!(F3));
    static assert(!isSafeTask!(F4));

    alias uint[] function(uint, string) pure @trusted F5;
    static assert(isSafeTask!(F5));
}

// This function decides whether Tasks that meet all of the other requirements
// for being executed from @safe code can be executed on a TaskPool.
// When executing via TaskPool, it's theoretically possible
// to return a value that is also pointed to by a worker thread's thread local
// storage.  When executing from executeInNewThread(), the thread that executed
// the Task is terminated by the time the return value is visible in the calling
// thread, so this is a non-issue.  It's also a non-issue for pure functions
// since they can't read global state.
private template isSafeReturn(T) {
    static if(!hasUnsharedAliasing!(T.ReturnType)) {
        enum isSafeReturn = true;
    } else static if(T.isPure) {
        enum isSafeReturn = true;
    } else {
        enum isSafeReturn = false;
    }
}

private T* moveToHeap(T)(ref T object) {
    GC.BlkAttr gcFlags = (typeid(T).flags & 1) ?
                          cast(GC.BlkAttr) 0 :
                          GC.BlkAttr.NO_SCAN;
    T* myPtr = cast(T*) GC.malloc(T.sizeof, gcFlags);

    core.stdc.string.memcpy(myPtr, &object, T.sizeof);
    object = T.init;

    return myPtr;
}

//------------------------------------------------------------------------------
/* Various classes of task.  These use manual C-style polymorphism, the kind
 * with lots of structs and pointer casting.  This is because real classes
 * would prevent some of the allocation tricks I'm using and waste space on
 * monitors and vtbls for something that needs to be ultra-efficient.
 */

private enum TaskState : ubyte {
    notStarted,
    inProgress,
    done
}

// This is conceptually the base class for all Task types.  The only Task type
// that is public is the one actually named Task.  There is also a slightly
// customized ParallelForeachTask and MapTask.
private template BaseMixin(ubyte initTaskStatus) {
    AbstractTask* prev;
    AbstractTask* next;

    static if(is(typeof(&impl))) {
        void function(void*) runTask = &impl;
    } else {
        void function(void*) runTask;
    }

    Throwable exception;
    ubyte taskStatus = initTaskStatus;


    /* Kludge:  Some tasks need to re-submit themselves after they finish.
     * In this case, they will set themselves to TaskState.notStarted before
     * resubmitting themselves.  Setting this flag to false prevents them
     * from being set to done in tryDeleteExecute.*/
    bool shouldSetDone = true;

    bool done() @property {
        if(atomicReadUbyte(taskStatus) == TaskState.done) {
            if(exception) {
                throw exception;
            }

            return true;
        }

        return false;
    }
}

// This is physically base "class" for all of the other tasks.
private struct AbstractTask {
    mixin BaseMixin!(TaskState.notStarted);

    void job() {
        runTask(&this);
    }
}

private template AliasReturn(alias fun, T...) {
    alias AliasReturnImpl!(fun, T).ret AliasReturn;
}

private template AliasReturnImpl(alias fun, T...) {
    private T args;
    alias typeof(fun(args)) ret;
}

// Should be private, but std.algorithm.reduce is used in the zero-thread case
// and won't work w/ private.
template reduceAdjoin(functions...) {
    static if(functions.length == 1) {
        alias binaryFun!(functions[0]) reduceAdjoin;
    } else {
        T reduceAdjoin(T, U)(T lhs, U rhs) {
            alias staticMap!(binaryFun, functions) funs;

            foreach(i, Unused; typeof(lhs.expand)) {
                lhs.expand[i] = funs[i](lhs.expand[i], rhs);
            }

            return lhs;
        }
    }
}

private template reduceFinish(functions...) {
    static if(functions.length == 1) {
        alias binaryFun!(functions[0]) reduceFinish;
    } else {


        T reduceFinish(T)(T lhs, T rhs) {
            alias staticMap!(binaryFun, functions) funs;

            foreach(i, Unused; typeof(lhs.expand)) {
                lhs.expand[i] = funs[i](lhs.expand[i], rhs.expand[i]);
            }

            return lhs;
        }
    }
}

private template ElementsCompatible(R, A) {
    static if(!isArray!A) {
        enum bool ElementsCompatible = false;
    } else {
        enum bool ElementsCompatible =
            is(ElementType!R : ElementType!A);
    }
}

/**
$(D Task) represents the fundamental unit of work.  A $(D Task) may be
executed in parallel with any other $(D Task).  Using this struct directly
allows future/promise _parallelism.  In this paradigm, a function (or delegate
or other callable) is executed in a thread other than the one it was called
from.  The calling thread does not block while the function is being executed.
A call to $(D workForce), $(D yieldForce), or $(D spinForce) is used to
ensure that the $(D Task) has finished executing and to obtain the return
value, if any.

The $(XREF parallelism, task) and $(XREF parallelism, scopedTask) functions can
be used to create an instance of this struct.  See $(D task) for usage examples.

Function results are returned from $(D yieldForce), $(D spinForce) and
$(D workForce) by ref.  If $(D fun) returns by ref, the reference will point
to the returned reference of $(D fun).  Otherwise it will point to a
field in this struct.

Copying of this struct is disabled, since it would provide no useful semantics.
If you want to pass this struct around, you should do so by reference or
pointer.

Bugs:  Changes to $(D ref) and $(D out) arguments are not propagated to the
       call site, only to $(D args) in this struct.

       Copying is not actually disabled yet due to compiler bugs.  In the
       mean time, please understand that if you copy this struct, you're
       relying on implementation bugs.
*/
struct Task(alias fun, Args...) {
    // Work around syntactic ambiguity w.r.t. address of function return vals.
    private static T* addressOf(T)(ref T val) {
        return &val;
    }

    private static void impl(void* myTask) {
        Task* myCastedTask = cast(typeof(this)*) myTask;
        static if(is(ReturnType == void)) {
            fun(myCastedTask._args);
        } else static if(is(typeof(addressOf(fun(myCastedTask._args))))) {
            myCastedTask.returnVal = addressOf(fun(myCastedTask._args));
        } else {
            myCastedTask.returnVal = fun(myCastedTask._args);
        }
    }
    mixin BaseMixin!(TaskState.notStarted) Base;

    private TaskPool pool;
    private bool isScoped;  // True if created with scopedTask.

    Args _args;

    /**
    The arguments the function was called with.  Changes to $(D out) and
    $(D ref) arguments will be visible here.
    */
    static if(__traits(isSame, fun, run)) {
        alias _args[1..$] args;
    } else {
        alias _args args;
    }


    // The purpose of this code is to decide whether functions whose
    // return values have unshared aliasing can be executed via
    // TaskPool from @safe code.  See isSafeReturn.
    static if(__traits(isSame, fun, run)) {
        static if(isFunctionPointer!(_args[0])) {
            private enum bool isPure =
                functionAttributes!(Args[0]) & FunctionAttribute.PURE;
        } else {
            // BUG:  Should check this for delegates too, but std.traits
            //       apparently doesn't allow this.  isPure is irrelevant
            //       for delegates, at least for now since shared delegates
            //       don't work.
            private enum bool isPure = false;
        }

    } else {
        // We already know that we can't execute aliases in @safe code, so
        // just put a dummy value here.
        private enum bool isPure = false;
    }


    /**
    The return type of the function called by this $(D Task).  This can be
    $(D void).
    */
    alias typeof(fun(_args)) ReturnType;

    static if(!is(ReturnType == void)) {
        static if(is(typeof(&fun(_args)))) {
            // Ref return.
            ReturnType* returnVal;

            ref ReturnType fixRef(ReturnType* val) {
                return *val;
            }

        } else {
            ReturnType returnVal;

            ref ReturnType fixRef(ref ReturnType val) {
                return val;
            }
        }
    }

    private void enforcePool() {
        enforce(this.pool !is null, "Job not submitted yet.");
    }

    private this(Args args) {
        static if(args.length > 0) {
            _args = args;
        }
    }

    /**
    If the $(D Task) isn't started yet, execute it in the current thread.
    If it's done, return its return value, if any.  If it's in progress,
    busy spin until it's done, then return the return value.  If it threw
    an exception, rethrow that exception.

    This function should be used when you expect the result of the
    $(D Task) to be available on a timescale shorter than that of an OS
    context switch.
     */
    @property ref ReturnType spinForce() @trusted {
        enforcePool();

        this.pool.tryDeleteExecute( cast(AbstractTask*) &this);

        while(atomicReadUbyte(this.taskStatus) != TaskState.done) {}

        if(exception) {
            throw exception;
        }

        static if(!is(ReturnType == void)) {
            return fixRef(this.returnVal);
        }
    }

    /**
    If the $(D Task) isn't started yet, execute it in the current thread.
    If it's done, return its return value, if any.  If it's in progress,
    wait on a condition variable.  If it threw an exception, rethrow that
    exception.

    This function should be used for expensive functions, as waiting on a
    condition variable introduces latency, but avoids wasted CPU cycles.
     */
    @property ref ReturnType yieldForce() @trusted {
        enforcePool();
        this.pool.tryDeleteExecute( cast(AbstractTask*) &this);

        if(done) {
            static if(is(ReturnType == void)) {
                return;
            } else {
                return fixRef(this.returnVal);
            }
        }

        pool.lock();
        scope(exit) pool.unlock();

        while(atomicReadUbyte(this.taskStatus) != TaskState.done) {
            pool.waitUntilCompletion();
        }

        if(exception) {
            throw exception;
        }

        static if(!is(ReturnType == void)) {
            return fixRef(this.returnVal);
        }
    }

    /**
    If this $(D Task) was not started yet, execute it in the current
    thread.  If it is finished, return its result.  If it is in progress,
    execute any other $(D Task) from the $(D TaskPool) instance that
    this $(D Task) was submitted to until this one
    is finished.  If it threw an exception, rethrow that exception.
    If no other tasks are available or this $(D Task) was executed using
    $(D executeInNewThread), wait on a condition variable.
     */
    @property ref ReturnType workForce() @trusted {
        enforcePool();
        this.pool.tryDeleteExecute( cast(AbstractTask*) &this);

        while(true) {
            if(done) {  // done() implicitly checks for exceptions.
                static if(is(ReturnType == void)) {
                    return;
                } else {
                    return fixRef(this.returnVal);
                }
            }

            pool.lock();
            AbstractTask* job;
            try {
                // Locking explicitly and calling popNoSync() because
                // pop() waits on a condition variable if there are no Tasks
                // in the queue.
                job = pool.popNoSync();
            } finally {
                pool.unlock();
            }

            if(job !is null) {

                version(verboseUnittest) {
                    stderr.writeln("Doing workForce work.");
                }

                pool.doJob(job);

                if(done) {
                    static if(is(ReturnType == void)) {
                        return;
                    } else {
                        return fixRef(this.returnVal);
                    }
                }
            } else {
                version(verboseUnittest) {
                    stderr.writeln("Yield from workForce.");
                }

                return yieldForce();
            }
        }
    }

    /**
    Returns $(D true) if the $(D Task) is finished executing.

    Throws:  Rethrows any exception thrown during the execution of the
             $(D Task).
    */
    @property bool done() @trusted {
        // Explicitly forwarded for documentation purposes.
        return Base.done;
    }

    /**
    Create a new thread for executing this $(D Task), execute it in the
    newly created thread, then terminate the thread.  This can be used for
    future/promise parallelism.  An explicit priority may be given
    to the $(D Task).  If one is provided, its value is forwarded to
    $(D core.thread.Thread.priority). See $(XREF parallelism, task) for
    usage example.
    */
    void executeInNewThread() @trusted {
        pool = new TaskPool(cast(AbstractTask*) &this);
    }

    /// Ditto
    void executeInNewThread(int priority) @trusted {
        pool = new TaskPool(cast(AbstractTask*) &this, priority);
    }

    @safe ~this() {
        if(isScoped && pool !is null && taskStatus != TaskState.done) {
            yieldForce();
        }
    }

    // When this is uncommented, it somehow gets called even though it's
    // disabled and Bad Things Happen.
    //@disable this(this) { assert(0);}
}


// Calls $(D fpOrDelegate) with $(D args).  This is an
// adapter that makes $(D Task) work with delegates, function pointers and
// functors instead of just aliases.
ReturnType!(F) run(F, Args...)(F fpOrDelegate, ref Args args) {
    return fpOrDelegate(args);
}


/**
Creates a $(D Task) on the GC heap that calls an alias.  This may be executed
via $(D Task.executeInNewThread) or by submitting to a
$(XREF parallelism, TaskPool).  A globally accessible instance of
$(D TaskPool) is provided by $(XREF parallelism, taskPool).

Returns:  A pointer to the $(D Task).

Examples:
---
// Read two files into memory at the same time.
import std.file;

void main() {
    // Create and execute a Task for reading foo.txt.
    auto file1Task = task!read("foo.txt");
    file1Task.executeInNewThread();

    // Read bar.txt in parallel.
    auto file2Data = read("bar.txt");

    // Get the results of reading foo.txt.
    auto file1Data = file1Task.yieldForce();
}
---

---
// Sorts an array using a parallel quick sort algorithm.  The first partition
// is done serially.  Both recursion branches are then executed in
// parallel.
//
// Timings for sorting an array of 1,000,000 doubles on an Athlon 64 X2
// dual core machine:
//
// This implementation:               176 milliseconds.
// Equivalent serial implementation:  280 milliseconds
void parallelSort(T)(T[] data) {
    // Sort small subarrays serially.
    if(data.length < 100) {
         std.algorithm.sort(data);
         return;
    }

    // Partition the array.
    swap(data[$ / 2], data[$ - 1]);
    auto pivot = data[$ - 1];
    bool lessThanPivot(T elem) { return elem < pivot; }

    auto greaterEqual = partition!lessThanPivot(data[0..$ - 1]);
    swap(data[$ - greaterEqual.length - 1], data[$ - 1]);

    auto less = data[0..$ - greaterEqual.length - 1];
    greaterEqual = data[$ - greaterEqual.length..$];

    // Execute both recursion branches in parallel.
    auto recurseTask = task!(parallelSort)(greaterEqual);
    taskPool.put(recurseTask);
    parallelSort(less);
    recurseTask.yieldForce();
}
---
*/
auto task(alias fun, Args...)(Args args) {
    alias Task!(fun, Args) RetType;
    auto stack = RetType(args);
    return moveToHeap(stack);
}

/**
Create a $(D Task) on the GC heap that calls a function pointer, delegate, or
class/struct with overloaded opCall.

Examples:
---
// Read two files in at the same time again, but this time use a function
// pointer instead of an alias to represent std.file.read.
import std.file;

void main() {
    // Create and execute a Task for reading foo.txt.
    auto file1Task = task(&read, "foo.txt");
    file1Task.executeInNewThread();

    // Read bar.txt in parallel.
    auto file2Data = read("bar.txt");

    // Get the results of reading foo.txt.
    auto file1Data = file1Task.yieldForce();
}
---

Notes: This function takes a non-scope delegate, meaning it can be
       used with closures.  If you can't allocate a closure due to objects
       on the stack that have scoped destruction, see $(D scopedTask), which
       takes a scope delegate.
 */
auto task(F, Args...)(F delegateOrFp, Args args)
if(is(typeof(delegateOrFp(args))) && !isSafeTask!F) {
    auto stack = Task!(run, TypeTuple!(F, Args))(delegateOrFp, args);
    return moveToHeap(stack);
}

/**
Version of Task, usable from $(D @safe) code.  Usage mechanics are
identical to the non-@safe case, but safety introduces the some restrictions.

1.  $(D fun) must be @safe or @trusted.

2.  $(D F) must not have any unshared aliasing as defined by
    $(XREF traits, hasUnsharedAliasing).  This means it
    may not be an unshared delegate or a non-shared class or struct
    with overloaded $(D opCall).  This also precludes accepting template
    alias parameters.

3.  $(D Args) must not have unshared aliasing.

4.  $(D fun) must not return by reference.

5.  The return type must not have unshared aliasing unless $(D fun) is
    $(D pure) or the $(D Task) is executed via $(D executeInNewThread) instead
    of using a $(D TaskPool).

*/
@trusted auto task(F, Args...)(F fun, Args args)
if(is(typeof(fun(args))) && isSafeTask!F) {
    auto stack = Task!(run, TypeTuple!(F, Args))(fun, args);
    return moveToHeap(stack);
}

/**
These functions allow the creation of $(D Task) objects on the stack rather
than the GC heap.  The lifetime of a $(D Task) created by $(D scopedTask)
cannot exceed the lifetime of the scope it was created in.

$(D scopedTask) might be preferred over $(D task):

1.  When a $(D Task) that calls a delegate is being created and a closure
    cannot be allocated due to objects on the stack that have scoped
    destruction.  The delegate overload of $(D scopedTask) takes a $(D scope)
    delegate.

2.  As a micro-optimization, to avoid the heap allocation associated with
    $(D task) or with the creation of a closure.

Usage is otherwise identical to $(D task).

Notes:  $(D Task) objects created using $(D scopedTask) will automatically
call $(D Task.yieldForce) in their destructor if necessary to ensure
the $(D Task) is complete before the stack frame they reside on is destroyed.
*/
auto scopedTask(alias fun, Args...)(Args args) {
    auto ret = Task!(fun, Args)(args);
    ret.isScoped = true;
    return ret;
}

/// Ditto
auto scopedTask(F, Args...)(scope F delegateOrFp, Args args)
if(is(typeof(delegateOrFp(args))) && !isSafeTask!F) {
    auto ret = Task!(run, TypeTuple!(F, Args))(delegateOrFp, args);
    ret.isScoped = true;
    return ret;
}

/// Ditto
@trusted auto scopedTask(F, Args...)(F fun, Args args)
if(is(typeof(fun(args))) && isSafeTask!F) {
    auto ret = typeof(return)(fun, args);
    ret.isScoped = true;
    return ret;
}

/**
The total number of CPU cores available on the current machine, as reported by
the operating system.
*/
immutable uint totalCPUs;

/**
This class encapsulates a task queue and a set of worker threads.  A task
queue is a simple FIFO queue of $(D Task) objects that have been submitted
to the $(D TaskPool) an are awaiting execution.  Its purpose
is to efficiently map a large number of $(D Task)s onto a smaller number of
threads.  A worker thread is a thread that executes the $(D Task) at the front
of the queue when one is available and sleeps when the queue is empty.

This class should usually be used via the default global instantiation,
available via the $(XREF parallelism, taskPool) property.
Occasionally it is useful to explicitly instantiate a $(D TaskPool):

1.  When you want $(D TaskPool) instances with multiple priorities, for example
    a low priority pool and a high priority pool.

2.  When the threads in the global task pool are waiting on a synchronization
    primitive (for example a mutex), and you want to parallelize the code that
    needs to run before these threads can be resumed.
 */
final class TaskPool {
private:

    // A pool can either be a regular pool or a single-task pool.  A
    // single-task pool is a dummy pool that's fired up for
    // Task.executeInNewThread().
    bool isSingleTask;

    union {
        Thread[] pool;
        Thread singleTaskThread;
    }

    AbstractTask* head;
    AbstractTask* tail;
    PoolState status = PoolState.running;
    Condition workerCondition;
    Condition waiterCondition;
    Mutex mutex;

    // The instanceStartIndex of the next instance that will be created.
    __gshared static size_t nextInstanceIndex = 1;

    // The index of the current thread.
    static size_t threadIndex;

    // The index of the first thread in this instance.
    immutable size_t instanceStartIndex;

    // The index that the next thread to be initialized in this pool will have.
    size_t nextThreadIndex;

    enum PoolState : ubyte {
        running,
        finishing,
        stopNow
    }

    void doJob(AbstractTask* job) {
        assert(job.taskStatus == TaskState.inProgress);
        assert(job.next is null);
        assert(job.prev is null);

        scope(exit) {
            if(!isSingleTask) {
                lock();
                notifyWaiters();
                unlock();
            }
        }

        try {
            job.job();
        } catch(Throwable e) {
            job.exception = e;
        }

        if(job.shouldSetDone) {
            atomicSetUbyte(job.taskStatus, TaskState.done);
        }
    }

    // This function is used for dummy pools created by Task.executeInNewThread().
    void doSingleTask() {
        // No synchronization.  Pool is guaranteed to only have one thread,
        // and the queue is submitted to before this thread is created.
        assert(head);
        auto t = head;
        t.next = t.prev = head = null;
        doJob(t);
    }

    // This work loop is used for a "normal" task pool where a worker thread
    // does more than one task.
    void workLoop() {
        // Initialize thread index.
        lock();
        threadIndex = nextThreadIndex;
        nextThreadIndex++;
        unlock();

        while(atomicReadUbyte(status) != PoolState.stopNow) {
            AbstractTask* task = pop();
            if (task is null) {
                if(atomicReadUbyte(status) == PoolState.finishing) {
                    atomicSetUbyte(status, PoolState.stopNow);
                    return;
                }
            } else {
                doJob(task);
            }
        }
    }

    bool deleteItem(AbstractTask* item) {
        lock();
        auto ret = deleteItemNoSync(item);
        unlock();
        return ret;
    }

    bool deleteItemNoSync(AbstractTask* item)
    out {
        assert(item.next is null);
        assert(item.prev is null);
    } body {
        if(item.taskStatus != TaskState.notStarted) {
            return false;
        }
        item.taskStatus = TaskState.inProgress;

        if(item is head) {
            // Make sure head gets set properly.
            popNoSync();
            return true;;
        }
        if(item is tail) {
            tail = tail.prev;
            if(tail !is null) {
                tail.next = null;
            }
            item.next = null;
            item.prev = null;
            return true;
        }
        if(item.next !is null) {
            assert(item.next.prev is item);  // Check queue consistency.
            item.next.prev = item.prev;
        }
        if(item.prev !is null) {
            assert(item.prev.next is item);  // Check queue consistency.
            item.prev.next = item.next;
        }
        item.next = null;
        item.prev = null;
        return true;
    }

    // Pop a task off the queue.
    AbstractTask* pop() {
        lock();
        auto ret = popNoSync();
        while(ret is null && status == PoolState.running) {
            wait();
            ret = popNoSync();
        }
        unlock();
        return ret;
    }

    AbstractTask* popNoSync()
    out(returned) {
        /* If task.prev and task.next aren't null, then another thread
         * can try to delete this task from the pool after it's
         * alreadly been deleted/popped.
         */
        if(returned !is null) {
            assert(returned.next is null);
            assert(returned.prev is null);
        }
    } body {
        if(isSingleTask) return null;

        AbstractTask* returned = head;
        if (head !is null) {
            head = head.next;
            returned.prev = null;
            returned.next = null;
            returned.taskStatus = TaskState.inProgress;
        }
        if(head !is null) {
            head.prev = null;
        }

        return returned;
    }

    // Push a task onto the queue.
    void abstractPut(AbstractTask* task) {
        lock();
        abstractPutNoSync(task);
        unlock();
    }

    void abstractPutNoSync(AbstractTask* task)
    out {
        assert(tail.prev !is tail);
        assert(tail.next is null, text(tail.prev, '\t', tail.next));
        if(tail.prev !is null) {
            assert(tail.prev.next is tail, text(tail.prev, '\t', tail.next));
        }
    } body {
        task.next = null;
        if (head is null) { //Queue is empty.
            head = task;
            tail = task;
            tail.prev = null;
        } else {
            task.prev = tail;
            tail.next = task;
            tail = task;
        }
        notify();
    }

    bool tryDeleteExecute(AbstractTask* toExecute) {
        if(isSingleTask) return false;

        if( !deleteItem(toExecute) ) {
            return false;
        }

        toExecute.job();

        /* shouldSetDone should always be true except if the task re-submits
         * itself to the pool and needs to bypass this.*/
        if(toExecute.shouldSetDone) {
            atomicSetUbyte(toExecute.taskStatus, TaskState.done);
        }

        return true;
    }

    size_t defaultBlockSize(size_t rangeLen) const pure nothrow @safe {
        if(this.size == 0) {
            return rangeLen;
        }

        immutable size_t fourSize = 4 * (this.size + 1);
        return (rangeLen / fourSize) + ((rangeLen % fourSize == 0) ? 0 : 1);
    }

    void lock() {
        if(!isSingleTask) mutex.lock();
    }

    void unlock() {
        if(!isSingleTask) mutex.unlock();
    }

    void wait() {
        if(!isSingleTask) workerCondition.wait();
    }

    void notify() {
        if(!isSingleTask) workerCondition.notify();
    }

    void notifyAll() {
        if(!isSingleTask) workerCondition.notifyAll();
    }

    void waitUntilCompletion() {
        if(isSingleTask) {
            singleTaskThread.join();
        } else {
            waiterCondition.wait();
        }
    }

    void notifyWaiters() {
        if(!isSingleTask) waiterCondition.notifyAll();
    }

    /*
    Gets the index of the current thread relative to this pool.  Any thread
    not in this pool will receive an index of 0.  The worker threads in
    this pool receive indices of 1 through this.size().

    The worker index is used for maintaining worker-local storage.
    */
    size_t workerIndex() {
        immutable rawInd = threadIndex;
        return (rawInd >= instanceStartIndex &&
                rawInd < instanceStartIndex + size) ?
                (rawInd - instanceStartIndex + 1) : 0;
    }

    // Private constructor for creating dummy pools that only have one thread,
    // only execute one Task, and then terminate.  This is used for
    // Task.executeInNewThread().
    this(AbstractTask* task, int priority = int.max) {
        assert(task);

        // Dummy value, not used.
        instanceStartIndex = 0;

        this.isSingleTask = true;
        task.taskStatus = TaskState.inProgress;
        this.head = task;
        singleTaskThread = new Thread(&doSingleTask);

        if(priority != int.max) {
            singleTaskThread.priority = priority;
        }

        singleTaskThread.start();
    }

public:

    /**
    Default constructor that initializes a $(D TaskPool) with
    $(D totalCPUs) - 1.  The minus 1 is included because the main thread
    will also be available to do work.

    Note:  In the case of a single-core machine, the primitives provided
           by $(D TaskPool) will operate transparently in single-threaded mode.
     */
    this() @trusted {
        this(totalCPUs - 1);
    }

    /**
    Allows for custom number of worker threads.
    */
    this(size_t nWorkers) @trusted {
        synchronized(TaskPool.classinfo) {
            instanceStartIndex = nextInstanceIndex;

            // The first worker thread to be initialized will have this index,
            // and will increment it.  The second worker to be initialized will
            // have this index plus 1.
            nextThreadIndex = instanceStartIndex;
            nextInstanceIndex += nWorkers;
        }

        mutex = new Mutex(this);
        workerCondition = new Condition(mutex);
        waiterCondition = new Condition(mutex);

        pool = new Thread[nWorkers];
        foreach(ref poolThread; pool) {
            poolThread = new Thread(&workLoop);
            poolThread.start();
        }
    }

    /**
    Implements a parallel foreach loop over a range.  This works by implicitly
    creating and submitting one $(D Task) to the $(D TaskPool) for each work
    unit.  A work unit may process one or more elements of $(D range).  The
    number of elements processed per work unit is controlled by the
    $(D workUnitSize) parameter.  Smaller work units provide better load
    balancing, but larger work units avoid the overhead of creating and
    submitting large numbers of $(D Task) objects.  The less time
    a single iteration of the loop takes, the larger $(D workUnitSize) should
    be.  For very expensive loop bodies, $(D workUnitSize) should  be 1.  An
    overload that chooses a default work unit size is also available.

    Examples:
    ---
    // Find the logarithm of every number from 1 to 1_000_000 in parallel.
    auto logs = new double[1_000_000];

    // Parallel foreach works with or without an index variable.  It can be
    // iterate by ref if range.front returns by ref.

    // Iterate over logs using work units of size 100.
    foreach(i, ref elem; taskPool.parallel(logs, 100)) {
        elem = log(i + 1.0);
    }

    // Same thing, but use the default work unit size.
    //
    // Timings on an Athlon 64 X2 dual core machine:
    //
    // Parallel foreach:  388 milliseconds
    // Regular foreach:   619 milliseconds
    foreach(i, ref elem; taskPool.parallel(logs)) {
        elem = log(i + 1.0);
    }
    ---

    Notes:

    This implementation lazily submits $(D Task) objects to the task queue.
    This means memory usage is constant in the length of $(D range) for fixed
    work unit size.

    Breaking from a parallel foreach loop via a break, labeled break,
    labeled continue, return or goto statement throws a
    $(D ParallelForeachError).

    In the case of non-random access ranges, parallel foreach buffers lazily
    to an array of size $(D workUnitSize) before executing the parallel portion
    of the loop.  The exception is that, if a parallel foreach is executed
    over a range returned by $(D asyncBuf) or $(D map), the copying is elided
    and the buffers are simply swapped.  In this case $(D workUnitSize) is
    ignored and the work unit size is set to the  buffer size $(D range).

    $(B Exception Handling):

    When at least one exception is thrown from inside a parallel foreach loop,
    the submission of additional $(D Task) objects is terminated as soon as
    possible, in a non-deterministic manner.  All executing or
    enqueued work units are allowed to complete.  Then, all exceptions that
    were thrown by any work unit are chained using $(D Throwable.next) and
    rethrown.  The order of the exception chaining is non-deterministic.
    */
    ParallelForeach!R parallel(R)(R range, size_t workUnitSize) {
        enforce(workUnitSize > 0, "workUnitSize must be > 0.");
        alias ParallelForeach!R RetType;
        return RetType(this, range, workUnitSize);
    }


    /// Ditto
    ParallelForeach!R parallel(R)(R range) {
        static if(hasLength!R) {
            // Default work unit size is such that we would use 4x as many
            // slots as are in this thread pool.
            size_t blockSize = defaultBlockSize(range.length);
            return parallel(range, blockSize);
        } else {
            // Just use a really, really dumb guess if the user is too lazy to
            // specify.
            return parallel(range, 512);
        }
    }

    /**
    Eager parallel map.  The eagerness of this function means it has less
    overhead than the lazily evaluated $(D TaskPool.map) and should be
    preferred where the memory requirements of eagerness are acceptable.
    $(D functions) are the functions to be evaluated, passed as template alias
    parameters in a style similar to $(XREF algorithm, map).  The first
    argument must be a random access range.

    ---
    auto numbers = iota(100_000_000);

    // Find the square roots of numbers.
    //
    // Timings on an Athlon 64 X2 dual core machine:
    //
    // Parallel eager map:                   0.802 s
    // Equivalent serial implementation:     1.768 s
    auto squareRoots = taskPool.amap!sqrt(numbers);
    ---

    Immediately after the range argument, an optional work unit size argument
    may be provided.  Work units as used by $(D amap) are identical to those
    defined for parallel foreach.  If no work unit size is provided, the
    default work unit size is used.

    ---
    // Same thing, but make work unit size 100.
    auto squareRoots = taskPool.amap!sqrt(numbers, 100);
    ---

    A buffer for returning the results may be provided as the last
    argument.  If one is not provided, one will be allocated on
    the garbage collected heap.  If one is provided, it must be the same length
    as the range.

    ---
    // Same thing, but explicitly allocate a buffer.  The element type of
    // the buffer may be either the exact type returned by functions or an
    // implicit conversion target.
    auto squareRoots = new float[numbers.length];
    taskPool.amap!sqrt(numbers, squareRoots);

    // Multiple functions, explicit buffer, and explicit work unit size.
    auto results = new Tuple!(float, real)[numbers.length];
    taskPool.amap!(sqrt, log)(numbers, 100, results);
    ---

    $(B Exception Handling):

    When at least one exception is thrown from inside the map functions,
    the submission of additional $(D Task) objects is terminated as soon as
    possible, in a non-deterministic manner.  All currently executing or
    enqueued work units are allowed to complete.  Then, all exceptions that
    were thrown from any work unit are chained using $(D Throwable.next) and
    rethrown.  The order of the exception chaining is non-deterministic.
     */
    template amap(functions...) {
        ///
        auto amap(Args...)(Args args) {
            static if(functions.length == 1) {
                alias unaryFun!(functions[0]) fun;
            } else {
                alias adjoin!(staticMap!(unaryFun, functions)) fun;
            }

            static if(Args.length > 1 && isArray!(Args[$ - 1]) &&
                is(MapType!(Args[0], functions) : ElementType!(Args[$ - 1]))) {
                alias args[$ - 1] buf;
                alias args[0..$ - 1] args2;
                alias Args[0..$ - 1] Args2;
            } else static if(isArray!(Args[$ - 1]) && Args.length > 1) {
                static assert(0, "Wrong buffer type.  Expected a " ~
                    MapType!(Args[0], functions).stringof ~ "[].  Got a " ~
                    Args[$ - 1].stringof ~ ".");
            } else {
                MapType!(Args[0], functions)[] buf;
                alias args args2;
                alias Args Args2;;
            }

            static if(isIntegral!(Args2[$ - 1])) {
                static assert(args2.length == 2);
                alias args2[0] range;
                auto blockSize = cast(size_t) args2[1];
            } else {
                static assert(args2.length == 1, Args);
                alias args2[0] range;
                auto blockSize = defaultBlockSize(range.length);
            }

            alias typeof(range) R;
            immutable len = range.length;

            if(buf.length == 0) {
                // Create buffer without initializing contents.
                alias MapType!(R, functions) MT;
                GC.BlkAttr gcFlags = (typeid(MT).flags & 1) ?
                                      cast(GC.BlkAttr) 0 :
                                      GC.BlkAttr.NO_SCAN;
                auto myPtr = cast(typeof(buf[0])*) GC.malloc(len *
                    typeof(buf[0]).sizeof, gcFlags);
                buf = myPtr[0..len];
            }
            enforce(buf.length == len,
                text("Can't use a user supplied buffer that's the wrong size.  ",
                "(Expected  :", len, " Got:  ", buf.length));
            if(blockSize > len) {
                blockSize = len;
            }

            // Handle as a special case:
            if(size == 0) {
                size_t index = 0;
                foreach(elem; range) {
                    buf[index++] = fun(elem);
                }
                return buf;
            }

            Throwable firstException, lastException;
            alias MapTask!(fun, R, typeof(buf)) MTask;
            MTask[] tasks = (cast(MTask*) alloca(this.size * MTask.sizeof * 2))
                            [0..this.size * 2];
            tasks[] = MTask.init;

            size_t curPos;
            void useTask(ref MTask task) {
                task.lowerBound = curPos;
                task.upperBound = min(len, curPos + blockSize);
                task.range = range;
                task.results = buf;
                task.pool = this;
                curPos += blockSize;

                lock();
                atomicSetUbyte(task.taskStatus, TaskState.notStarted);
                abstractPutNoSync(cast(AbstractTask*) &task);
                unlock();
            }

            ubyte doneSubmitting = 0;
            Task!(run, void delegate()) submitNextBatch;

            void submitJobs() {
                // Search for slots.
                foreach(ref task; tasks) {
                    mixin(parallelExceptionHandling);

                    useTask(task);
                    if(curPos >= len) {
                        atomicSetUbyte(doneSubmitting, 1);
                        return;
                    }
                }

                // Now that we've submitted all the worker tasks, submit
                // the next submission task.  Synchronizing on the pool
                // to prevent a deleting thread from deleting the job
                // before it's submitted.
                lock();
                atomicSetUbyte(submitNextBatch.taskStatus, TaskState.notStarted);
                abstractPutNoSync( cast(AbstractTask*) &submitNextBatch);
                unlock();
            }

            submitNextBatch = .scopedTask(&submitJobs);

            // The submitAndExecute mixin relies on the TaskPool instance
            // being called pool.
            TaskPool pool = this;

            mixin(submitAndExecute);

            return buf;
        }
    }

    /**
    A semi-lazy parallel map that can be used for pipelining.  The map
    functions are evaluated for the first $(D bufSize) elements and stored in a
    buffer and made available to $(D popFront).  Meanwhile, in the
    background a second buffer of the same size is filled.  When the first
    buffer is exhausted, it is swapped with the second buffer and filled while
    the values from what was originally the second buffer are read.  This
    implementation allows for elements to be written to the buffer without
    the need for atomic operations or synchronization for each write, and
    enables the mapping function to be evaluated efficiently in parallel.

    $(D map) has more overhead than the simpler procedure used by $(D amap)
    but avoids the need to keep all results in memory simultaneously and works
    with non-random access ranges.

    Parameters:

    $(D range):  The input range to be mapped.  If $(D range) is not random
    access it will be lazily buffered to an array of size $(D bufSize) before
    the map function is evaluated.  (For an exception to this rule, see Notes.)

    $(D bufSize):  The size of the buffer to store the evaluated elements.

    $(D workUnitSize):  The number of elements to evaluate in a single
    $(D Task).  Must be less than or equal to $(D bufSize), and
    should be a fraction of $(D bufSize) such that all worker threads can be
    used.  If the default of size_t.max is used, workUnitSize will be set to
    the pool-wide default.

    Returns:  An input range representing the results of the map.  This range
              has a length iff $(D range) has a length.

    Notes:

    If a range returned by $(D map) or $(D asyncBuf) is used as an input to
    $(D map), then as an optimization the copying from the output buffer
    of the first range to the input buffer of the second range is elided, even
    though the ranges returned by $(D map) and $(D asyncBuf) are non-random
    access ranges.  This means that the $(D bufSize) parameter passed to the
    current call to $(D map) will be ignored and the size of the buffer
    will be the buffer size of $(D range).

    Examples:
    ---
    // Pipeline reading a file, converting each line to a number, taking the
    // logarithms of the numbers, and performing the additions necessary to
    // find the sum of the logarithms.

    auto lineRange = File("numberList.txt").byLine();
    auto dupedLines = std.algorithm.map!"a.idup"(lineRange);
    auto nums = taskPool.map!(to!double)(dupedLines);
    auto logs = taskPool.map!log10(nums);

    double sum = 0;
    foreach(elem; logs) {
        sum += elem;
    }
    ---

    $(B Exception Handling):

    Any exceptions thrown while iterating over $(D range)
    or computing the map function are re-thrown on a call to $(D popFront).
    In the case of exceptions thrown while computing the map function,
    the exceptions are chained as in $(D TaskPool.amap).
    */
    template map(functions...) {

        ///
        auto
        map(R)(R range, size_t bufSize = 100, size_t workUnitSize = size_t.max)
        if(isInputRange!R) {
            enforce(workUnitSize == size_t.max || workUnitSize <= bufSize,
                "Work unit size must be smaller than buffer size.");
            static if(functions.length == 1) {
                alias unaryFun!(functions[0]) fun;
            } else {
                 alias adjoin!(staticMap!(unaryFun, functions)) fun;
            }

            static final class LazyMap {
                // This is a class because the task needs to be located on the heap
                // and in the non-random access case the range needs to be on the
                // heap, too.

            private:
                alias MapType!(R, functions) E;
                E[] buf1, buf2;
                R range;
                TaskPool pool;
                Task!(run, E[] delegate(E[]), E[]) nextBufTask;
                size_t workUnitSize;
                size_t bufPos;
                bool lastTaskWaited;

                static if(isRandomAccessRange!R) {
                    alias R FromType;

                    void popRange() {
                        static if(__traits(compiles, range[0..range.length])) {
                            range = range[min(buf1.length, range.length)..range.length];
                        } else static if(__traits(compiles, range[0..$])) {
                            range = range[min(buf1.length, range.length)..$];
                        } else {
                            static assert(0, "R must have slicing for LazyMap."
                                ~ "  " ~ R.stringof ~ " doesn't.");
                        }
                    }

                } else static if(is(typeof(range.buf1)) && is(typeof(range.bufPos)) &&
                  is(typeof(range.doBufSwap()))) {

                    version(unittest) {
                        pragma(msg, "LazyRange Special Case:  "
                            ~ typeof(range).stringof);
                    }

                    alias typeof(range.buf1) FromType;
                    FromType from;

                    // Just swap our input buffer with range's output buffer and get
                    // range mapping again.  No need to copy element by element.
                    FromType dumpToFrom() {
                        assert(range.buf1.length <= from.length);
                        from.length = range.buf1.length;
                        swap(range.buf1, from);
                        range._length -= (from.length - range.bufPos);
                        range.doBufSwap();

                        return from;
                    }

                } else {
                    alias ElementType!(R)[] FromType;

                    // The temporary array that data is copied to before being
                    // mapped.
                    FromType from;

                    FromType dumpToFrom() {
                        assert(from !is null);

                        size_t i;
                        for(; !range.empty && i < from.length; range.popFront()) {
                            from[i++] = range.front;
                        }

                        from = from[0..i];
                        return from;
                    }
                }

                static if(hasLength!R) {
                    size_t _length;

                    public @property size_t length() const pure nothrow @safe {
                        return _length;
                    }
                }

                this(R range, size_t bufSize, size_t workUnitSize, TaskPool pool) {
                    static if(is(typeof(range.buf1)) && is(typeof(range.bufPos)) &&
                    is(typeof(range.doBufSwap()))) {
                        bufSize = range.buf1.length;
                    }

                    buf1.length = bufSize;
                    buf2.length = bufSize;

                    static if(!isRandomAccessRange!R) {
                        from.length = bufSize;
                    }

                    this.workUnitSize = (workUnitSize == size_t.max) ?
                            pool.defaultBlockSize(bufSize) : workUnitSize;
                    this.range = range;
                    this.pool = pool;

                    static if(hasLength!R) {
                        _length = range.length;
                    }

                    fillBuf(buf1);
                    submitBuf2();
                }

                // The from parameter is a dummy and ignored in the random access
                // case.
                E[] fillBuf(E[] buf) {
                    static if(isRandomAccessRange!R) {
                        auto toMap = take(range, buf.length);
                        scope(success) popRange();
                    } else {
                        auto toMap = dumpToFrom();
                    }

                    buf = buf[0..min(buf.length, toMap.length)];
                    pool.amap!(functions)(
                            toMap,
                            workUnitSize,
                            buf
                        );

                    return buf;
                }

                void submitBuf2() {
                    // Hack to reuse the task object.

                    nextBufTask = typeof(nextBufTask).init;
                    nextBufTask._args[0] = &fillBuf;
                    nextBufTask._args[1] = buf2;
                    pool.put(nextBufTask);
                }

                void doBufSwap() {
                    if(lastTaskWaited) {
                        // Then the range is empty.  Signal it here.
                        buf1 = null;
                        buf2 = null;

                        static if(!isRandomAccessRange!R) {
                            from = null;
                        }

                        return;
                    }

                    buf2 = buf1;
                    buf1 = nextBufTask.yieldForce();
                    bufPos = 0;

                    if(range.empty) {
                        lastTaskWaited = true;
                    } else {
                        submitBuf2();
                    }
                }

            public:
                MapType!(R, functions) front() @property {
                    return buf1[bufPos];
                }

                void popFront() {
                    static if(hasLength!R) {
                        _length--;
                    }

                    bufPos++;
                    if(bufPos >= buf1.length) {
                        doBufSwap();
                    }
                }

                static if(std.range.isInfinite!R) {
                    enum bool empty = false;
                } else {

                    bool empty() @property {
                        return buf1 is null;  // popFront() sets this when range is empty
                    }
                }
            }
            return new LazyMap(range, bufSize, workUnitSize, this);
        }
    }

    /**
    Given an input range that is expensive to iterate over, returns an
    input range that asynchronously buffers the contents of
    $(D range) into a buffer of $(D bufSize) elements in a worker thread,
    while making prevously buffered elements from a second buffer, also of size
    $(D bufSize), available via the range interface of the returned
    object.  The returned range has a length iff $(D hasLength!(R)).
    $(D asyncBuf) is useful, for example, when performing expensive operations
    on the elements of ranges that represent data on a disk or network.

    Examples:
    ---
    auto lines = File("foo.txt").byLine();
    auto duped = std.algorithm.map!"a.idup"(lines);

    // Fetch more lines in the background while we process the lines already
    // read into memory into a matrix of doubles.
    double[][] matrix;
    auto asyncReader = taskPool.asyncBuf(duped);

    foreach(line; asyncReader) {
        auto ls = line.split("\t");
        matrix ~= to!(double[])(ls);
    }
    ---

    $(B Exception Handling):

    Any exceptions thrown while iterating over $(D range) are re-thrown on a
    call to $(D popFront).
    */
    auto asyncBuf(R)(R range, size_t bufSize = 100) {
        static final class AsyncBuf {
            // This is a class because the task and the range both need to be on
            // the heap.

            // The element type of R.
            alias ElementType!R E;  // Needs to be here b/c of forward ref bugs.

        private:
            E[] buf1, buf2;
            R range;
            TaskPool pool;
            Task!(run, E[] delegate(E[]), E[]) nextBufTask;
            size_t bufPos;
            bool lastTaskWaited;

            static if(hasLength!R) {
                size_t _length;

                // Available if hasLength!(R).
                public @property size_t length() const pure nothrow @safe {
                    return _length;
                }
            }

            this(R range, size_t bufSize, TaskPool pool) {
                buf1.length = bufSize;
                buf2.length = bufSize;

                this.range = range;
                this.pool = pool;

                static if(hasLength!R) {
                    _length = range.length;
                }

                fillBuf(buf1);
                submitBuf2();
            }

            // The from parameter is a dummy and ignored in the random access
            // case.
            E[] fillBuf(E[] buf) {
                assert(buf !is null);

                size_t i;
                for(; !range.empty && i < buf.length; range.popFront()) {
                    buf[i++] = range.front;
                }

                buf = buf[0..i];
                return buf;
            }

            void submitBuf2() {
                // Hack to reuse the task object.

                nextBufTask = typeof(nextBufTask).init;
                nextBufTask._args[0] = &fillBuf;
                nextBufTask._args[1] = buf2;
                pool.put(nextBufTask);
            }

            void doBufSwap() {
                if(lastTaskWaited) {
                    // Then the range is empty.  Signal it here.
                    buf1 = null;
                    buf2 = null;
                    return;
                }

                buf2 = buf1;
                buf1 = nextBufTask.yieldForce();
                bufPos = 0;

                if(range.empty) {
                    lastTaskWaited = true;
                } else {
                    submitBuf2();
                }
            }

        public:

            E front() @property {
                return buf1[bufPos];
            }

            void popFront() {
                static if(hasLength!R) {
                    _length--;
                }

                bufPos++;
                if(bufPos >= buf1.length) {
                    doBufSwap();
                }
            }

            static if(std.range.isInfinite!R) {
                enum bool empty = false;
            } else {

                ///
                bool empty() @property {
                    return buf1 is null;  // popFront() sets this when range is empty
                }
            }
        }
        return new AsyncBuf(range, bufSize, this);
    }

    /**
    Parallel reduce on a random access range.  Except as otherwise noted, usage
    is similar to $(XREF algorithm, reduce).  This function works by splitting
    the range to be reduced into work units, which are slices to be reduced in
    parallel.  Once the results from all work units are computed, a final serial
    reduction is performed on these results to compute the final answer.
    Therefore, care must be taken to choose the seed value appropriately.

    Because the reduction is being performed in parallel,
    $(D functions) must be associative.  For notational simplicity, let # be an
    infix operator representing $(D functions).  Then, (a # b) # c must equal
    a # (b # c).  Floating point addition is not associative
    even though addition in exact arithmetic is.  Summing floating
    point numbers using this function may give different results than summing
    serially.  However, for many practical purposes floating point addition
    can be treated as associative.

    An explicit seed may be provided as the first argument.  If
    provided, it is used as the seed for all work units and for the final
    reduction of results from all work units.  Therefore, if it is not the
    identity value for the operation being performed, results may differ from
    those generated by $(D std.algorithm.reduce) or depending on how many work
    units are used.  The next argument must be the range to be reduced.
    ---
    // Find the sum of squares of a range in parallel, using an explicit seed.
    //
    // Timings on an Athlon 64 X2 dual core machine:
    //
    // Parallel reduce:                     100 milliseconds
    // Using std.algorithm.reduce instead:  169 milliseconds
    auto nums = iota(10_000_000.0f);
    auto sumSquares = taskPool.reduce!"a + b * b"(0.0, nums);
    ---

    If no explicit seed is provided, the first element of each work unit
    is used as a seed.  For the final reduction, the result from the first
    work unit is used as the seed.
    ---
    // Find the sum of a range in parallel, using the first element of each
    // work unit as the seed.
    auto sum = taskPool.reduce!"a + b"(nums);
    ---

    An explicit work unit size may be specified as the last argument.
    Specifying too small a work unit size will effectively serialize the
    reduction, as the final reduction of the result of each work unit will
    dominate computation time.  If $(D TaskPool.size) for this instance
    is zero, this parameter is ignored and one work unit is used.
    ---
    // Use a work unit size of 100.
    auto sum2 = taskPool.reduce!"a + b"(nums, 100);

    // Work unit size of 100 and explicit seed.
    auto sum3 = taskPool.reduce!"a + b"(0.0, nums, 100);
    ---

    Parallel reduce supports multiple functions, like $(D std.algorithm.reduce).
    ---
    // Find both the min and max of nums.
    auto minMax = taskPool.reduce!(min, max)(nums);
    assert(minMax[0] == reduce!min(nums));
    assert(minMax[1] == reduce!max(nums));
    ---

    $(B Exception Handling):

    After this function is finished executing, any exceptions thrown
    are chained together via $(D Throwable.next) and rethrown.  The chaining
    order is non-deterministic.
     */
    template reduce(functions...) {

        ///
        auto reduce(Args...)(Args args) {
            alias reduceAdjoin!(functions) fun;
            alias reduceFinish!(functions) finishFun;

            static if(isIntegral!(Args[$ - 1])) {
                size_t blockSize = cast(size_t) args[$ - 1];
                alias args[0..$ - 1] args2;
                alias Args[0..$ - 1] Args2;
            } else {
                alias args args2;
                alias Args Args2;
            }

            auto makeStartValue(Type)(Type e) {
                static if(functions.length == 1) {
                    return e;
                } else {
                    typeof(adjoin!(staticMap!(binaryFun, functions))(e, e))
                        seed = void;
                    foreach (i, T; seed.Types) {
                        auto p = (cast(void*) &seed.expand[i])
                            [0 .. seed.expand[i].sizeof];
                        emplace!T(p, e);
                    }

                    return seed;
                }
            }

            static if(args2.length == 2) {
                static assert(isInputRange!(Args2[1]));
                alias args2[1] range;
                alias args2[0] seed;
                enum explicitSeed = true;

                static if(!is(typeof(blockSize))) {
                    size_t blockSize = defaultBlockSize(range.length);
                }
            } else {
                static assert(args2.length == 1);
                alias args2[0] range;

                static if(!is(typeof(blockSize))) {
                    size_t blockSize = defaultBlockSize(range.length);
                }


                enforce(!range.empty,
                    "Cannot reduce an empty range with first element as start value.");

                auto seed = makeStartValue(range.front);
                enum explicitSeed = false;
                range.popFront();
            }

            alias typeof(seed) E;
            alias typeof(range) R;

            if(this.size == 0) {
                return std.algorithm.reduce!(fun)(seed, range);
            }

            // Unlike the rest of the functions here, I can't use the Task object
            // recycling trick here because this has to work on non-commutative
            // operations.  After all the tasks are done executing, fun() has to
            // be applied on the results of these to get a final result, but
            // it can't be evaluated out of order.

            immutable len = range.length;
            if(blockSize > len) {
                blockSize = len;
            }

            immutable size_t nWorkUnits = (len / blockSize) +
                ((len % blockSize == 0) ? 0 : 1);
            assert(nWorkUnits * blockSize >= len);

            static E reduceOnRange
            (E seed, R range, size_t lowerBound, size_t upperBound) {
                E result = seed;
                foreach(i; lowerBound..upperBound) {
                    result = fun(result, range[i]);
                }
                return result;
            }

            alias Task!(reduceOnRange, E, R, size_t, size_t) RTask;
            RTask[] tasks;

            enum MAX_STACK = 512;
            immutable size_t nBytesNeeded = nWorkUnits * RTask.sizeof;

            if(nBytesNeeded < MAX_STACK) {
                tasks = (cast(RTask*) alloca(nBytesNeeded))[0..nWorkUnits];
                tasks[] = RTask.init;
            } else {
                tasks = new RTask[nWorkUnits];
            }

            size_t curPos = 0;
            void useTask(ref RTask task) {
                task.args[3] = min(len, curPos + blockSize);  // upper bound.
                task.args[1] = range;  // range

                static if(explicitSeed) {
                    task.args[2] = curPos; // lower bound.
                    task.args[0] = seed;
                } else {
                    task.args[2] = curPos + 1; // lower bound.
                    task.args[0] = makeStartValue(range[curPos]);
                }

                curPos += blockSize;
                put(task);
            }

            foreach(ref task; tasks) {
                useTask(task);
            }

            // Try to execute each of these in the current thread
            foreach(ref task; tasks) {
                tryDeleteExecute( cast(AbstractTask*) &task);
            }

            // Now that we've tried to execute every task, they're all either
            // done or in progress.  Force all of them.
            E result = seed;

            Throwable firstException, lastException;

            foreach(ref task; tasks) {
                try {
                    task.yieldForce();
                } catch(Throwable e) {
                    addToChain(e, firstException, lastException);
                    continue;
                }

                if(!firstException) result = finishFun(result, task.returnVal);
            }

            if(firstException) throw firstException;

            return result;
        }
    }

    /**
    Struct for creating worker-local storage.  Worker-local storage is
    thread-local storage that exists only for worker threads in a given
    $(D TaskPool) plus a single thread outside the pool.  It is allocated on the
    garbage collected heap in a way that avoids false sharing, and doesn't
    necessarily have global scope within any thread.  It can be accessed from
    any worker thread in the $(D TaskPool) that created it, and one thread
    outside this $(D TaskPool).  All threads outside the pool that created a
    given instance of worker-local storage share a single slot.

    Since the underlying data for this struct is heap-allocated, this struct
    has reference semantics when passed between functions.

    The main uses cases for $(D WorkerLocalStorageStorage) are:

    1.  Performing parallel reductions with an imperative, as opposed to
    functional, programming style.  In this case, it's useful to treat
    $(D WorkerLocalStorageStorage) as local to each thread for only the parallel
    portion of an algorithm.

    2.  Recycling temporary buffers across iterations of a parallel foreach loop.

    Examples:
    ---
    // Calculate pi as in our synopsis example, but use an imperative instead
    // of a functional style.
    immutable n = 1_000_000_000;
    immutable delta = 1.0L / n;

    auto sums = taskPool.workerLocalStorage(0.0L);
    foreach(i; parallel(iota(n))) {
        immutable x = ( i - 0.5L ) * delta;
        immutable toAdd = delta / ( 1.0 + x * x );
        sums.get = sums.get + toAdd;
    }

    // Add up the results from each worker thread.
    real pi = 0;
    foreach(threadResult; sums.toRange) {
        pi += 4.0L * threadResult;
    }
    ---
     */
    static struct WorkerLocalStorage(T) {
    private:
        TaskPool pool;
        size_t size;

        static immutable size_t cacheLineSize;
        size_t elemSize;
        bool* stillThreadLocal;

        shared static this() {
            size_t lineSize = 0;
            foreach(cachelevel; datacache) {
                if(cachelevel.lineSize > lineSize && cachelevel.lineSize < uint.max) {
                    lineSize = cachelevel.lineSize;
                }
            }

            cacheLineSize = lineSize;
        }

        static size_t roundToLine(size_t num) pure nothrow {
            if(num % cacheLineSize == 0) {
                return num;
            } else {
                return ((num / cacheLineSize) + 1) * cacheLineSize;
            }
        }

        void* data;

        void initialize(TaskPool pool) {
            this.pool = pool;
            size = pool.size + 1;
            stillThreadLocal = new bool;
            *stillThreadLocal = true;

            // Determines whether the GC should scan the array.
            auto blkInfo = (typeid(T).flags & 1) ?
                           cast(GC.BlkAttr) 0 :
                           GC.BlkAttr.NO_SCAN;

            immutable nElem = pool.size + 1;
            elemSize = roundToLine(T.sizeof);

            // The + 3 is to pad one full cache line worth of space on either side
            // of the data structure to make sure false sharing with completely
            // unrelated heap data is prevented, and to provide enough padding to
            // make sure that data is cache line-aligned.
            data = GC.malloc(elemSize * (nElem + 3), blkInfo) + elemSize;

            // Cache line align data ptr.
            data = cast(void*) roundToLine(cast(size_t) data);

            foreach(i; 0..nElem) {
                this.opIndex(i) = T.init;
            }
        }

        ref T opIndex(size_t index) {
            assert(index < size, text(index, '\t', uint.max));
            return *(cast(T*) (data + elemSize * index));
        }

        void opIndexAssign(T val, size_t index) {
            assert(index < size);
            *(cast(T*) (data + elemSize * index)) = val;
        }

    public:
        /**
        Get the current thread's instance.  Returns by ref.
        Note that calling $(D get) from any thread
        outside the $(D TaskPool) that created this instance will return the
        same reference, so an instance of worker-local storage should only be
        accessed from one thread outside the pool that created it.  If this
        rule is violated, undefined behavior will result.

        If assertions are enabled and $(D toRange) has been called, then this
        WorkerLocalStorage instance is no longer worker-local and an assertion
        failure will result when calling this method.  This is not checked
        when assertions are disabled for performance reasons.
         */
        ref T get() @property {
            assert(*stillThreadLocal,
                   "Cannot call get() on this instance of WorkerLocalStorage because it" ~
                   " is no longer worker-local."
            );
            return opIndex(pool.workerIndex);
        }

        /**
        Assign a value to the current thread's instance.  This function has
        the same caveats as its overload.
        */
        void get(T val) @property {
            assert(*stillThreadLocal,
                   "Cannot call get() on this instance of WorkerLocalStorage because it" ~
                   " is no longer worker-local."
            );

            opIndexAssign(val, pool.workerIndex);
        }

        /**
        Returns a range view of the values for all threads, which can be used
        to further process the results of each thread after running the parallel
        part of your algorithm.  Do not use this method in the parallel portion
        of your algorithm.

        Calling this function sets a flag indicating that this struct is no
        longer worker-local, and attempting to use the $(D get) method again
        will result in an assertion failure if assertions are enabled.
         */
        WorkerLocalStorageRange!T toRange() @property {
            if(*stillThreadLocal) {
                *stillThreadLocal = false;

                // Make absolutely sure results are visible to all threads.
                synchronized {}
            }

           return WorkerLocalStorageRange!(T)(this);
        }
    }

    /**
    Range primitives for worker-local storage.  The purpose of this is to
    access results produced by each worker thread from a single thread once you
    are no longer using the worker-local storage from multiple threads.
    Do not use this struct in the parallel portion of your algorithm.

    The proper way to instantiate this object is to call
    $(D WorkerLocalStorage.toRange).  Once instantiated, this object behaves
    as a finite random-access range with assignable, lvalue elemends and
    a length equal to the number of worker threads in the $(D TaskPool) that
    created it plus 1.
     */
    static struct WorkerLocalStorageRange(T) {
    private:
        WorkerLocalStorage!T workerLocalStorage;

        size_t _length;
        size_t beginOffset;

        this(WorkerLocalStorage!(T) wl) {
            this.workerLocalStorage = wl;
            _length = wl.size;
        }

    public:
        ref T front() @property {
            return this[0];
        }

        ref T back() @property {
            return this[_length - 1];
        }

        void popFront() {
            if(_length > 0) {
                beginOffset++;
                _length--;
            }
        }

        void popBack() {
            if(_length > 0) {
                _length--;
            }
        }

        typeof(this) save() @property {
            return this;
        }

        ref T opIndex(size_t index) {
            assert(index < _length);
            return workerLocalStorage[index + beginOffset];
        }

        void opIndexAssign(T val, size_t index) {
            assert(index < _length);
            workerLocalStorage[index] = val;
        }

        typeof(this) opSlice(size_t lower, size_t upper) {
            assert(upper <= _length);
            auto newWl = this.workerLocalStorage;
            newWl.data += lower * newWl.elemSize;
            newWl.size = upper - lower;
            return typeof(this)(newWl);
        }

        bool empty() @property {
            return length == 0;
        }

        size_t length() @property {
            return _length;
        }
    }

    /**
    Create an instance of worker-local storage, initialized with a given
    value.  The value is $(D lazy) so that you can, for example, easily
    create one instance of a class for each worker.  For usage example,
    see the $(D WorkerLocalStorage) struct.
     */
    WorkerLocalStorage!(T) workerLocalStorage(T)(lazy T initialVal = T.init) {
        WorkerLocalStorage!(T) ret;
        ret.initialize(this);
        foreach(i; 0..size + 1) {
            ret[i] = initialVal;
        }
        synchronized {}  // Make sure updates are visible in all threads.
        return ret;
    }

    /**
    Signals to all worker threads to terminate as soon as they are finished
    with their current $(D Task), or immediately if they are not executing a
    $(D Task).  $(D Task)s that were in queue will not be executed unless
    a call to $(D Task.workForce), $(D Task.yieldForce) or $(D Task.spinForce)
    causes them to be executed.

    Use only if you have waitied on every $(D Task) and therefore know the
    queue is empty, or if you speculatively executed some tasks and no longer
    need the results.
     */
    void stop() @trusted {
        lock();
        scope(exit) unlock();
        atomicSetUbyte(status, PoolState.stopNow);
        notifyAll();
    }

    /*
    Waits for all jobs to finish, then terminates all worker threads.  Blocks
    until all worker threads have terminated.

    Example:
    ---
    import std.file;

    auto pool = new TaskPool();
    auto task1 = task!read("foo.txt");
    pool.put(task1);
    auto task2 = task!read("bar.txt");
    pool.put(task2);
    auto task3 = task!read("baz.txt");
    pool.put(task3);

    // Call join() to guarantee that all tasks are done running, the worker
    // threads have terminated and that the results of all of the tasks can
    // be accessed without any synchronization primitives.
    pool.join();

    // Use spinForce() since the results are guaranteed to have been computed
    // and spinForce() is the cheapest of the force functions.
    auto result1 = task1.spinForce();
    auto result2 = task2.spinForce();
    auto result3 = task3.spinForce();
    ---
    */
    version(none) {
        void join() @trusted {
            finish();
            foreach(t; pool) {
                t.join();
            }
        }
    }

    /**
    Signals worker threads to terminate when the queue becomes empty.  Does
    not block.
     */
    void finish() @trusted {
        lock();
        scope(exit) unlock();
        atomicCasUbyte(status, PoolState.running, PoolState.finishing);
        notifyAll();
    }

    /// Returns the number of worker threads in the pool.
    @property size_t size() @safe const pure nothrow {
        return pool.length;
    }

    /**
    Put a $(D Task) object on the back of the task queue.  The $(D Task)
    object may be passed by pointer or reference.

    Example:
    ---
    import std.file;

    // Create a task.
    auto t = task!read("foo.txt");

    // Add it to the queue to be executed.
    taskPool.put(t);
    ---

    Notes:

    @trusted overloads of this function are called for $(D Task)s if
    $(XREF traits, hasUnsharedAliasing) is false for the $(D Task)'s
    return type or the function the $(D Task) executes is $(D pure).
    $(D Task) objects that meet all other requirements specified in the
    $(D @trusted) overloads of $(D task) and $(D scopedTask) may be created
    and executed from $(D @safe) code via $(D Task.executeInNewThread) but
    not via $(D TaskPool).

    While this function takes the address of variables that may
    be on the stack, some overloads are marked as @trusted.
    $(D Task) includes a destructor that waits for the task to complete
    before destroying the stack frame it is allocated on.  Therefore,
    it is impossible for the stack frame to be destroyed before the task is
    complete and no longer referenced by a $(D TaskPool).
    */
    void put(alias fun, Args...)(ref Task!(fun, Args) task)
    if(!isSafeReturn!(typeof(task))) {
        task.pool = this;
        abstractPut( cast(AbstractTask*) &task);
    }

    /// Ditto
    void put(alias fun, Args...)(Task!(fun, Args)* task)
    if(!isSafeReturn!(typeof(*task))) {
        enforce(task !is null, "Cannot put a null Task on a TaskPool queue.");
        put(*task);
    }

    @trusted void put(alias fun, Args...)(ref Task!(fun, Args) task)
    if(isSafeReturn!(typeof(task))) {
        task.pool = this;
        abstractPut( cast(AbstractTask*) &task);
    }

    @trusted void put(alias fun, Args...)(Task!(fun, Args)* task)
    if(isSafeReturn!(typeof(*task))) {
        enforce(task !is null, "Cannot put a null Task on a TaskPool queue.");
        put(*task);
    }

    /**
    These properties control whether the worker threads are daemon threads.
    A daemon thread is automatically terminated when all non-daemon threads
    have terminated.  A non-daemon thread will prevent a program from
    terminating as long as it has not terminated.

    If any $(D TaskPool) with non-daemon threads is active, either $(D stop)
    or $(D finish) must be called on it before the program can terminate.

    The worker treads in the $(D TaskPool) instance returned by the
    $(D taskPool) property are daemon by default.  The worker threads of
    manually instantiated task pools are non-daemon by default.

    Note:  For a size zero pool, the getter arbitrarily returns true and the
           setter has no effect.
    */
    bool isDaemon() @property @trusted {
        lock();
        scope(exit) unlock();
        return (size == 0) ? true : pool[0].isDaemon();
    }

    /// Ditto
    void isDaemon(bool newVal) @property @trusted {
        lock();
        scope(exit) unlock();
        foreach(thread; pool) {
            thread.isDaemon = newVal;
        }
    }

    /**
    These functions allow getting and setting the OS scheduling priority of
    the worker threads in this $(D TaskPool).  They forward to
    $(D core.thread.Thread.priority), so a given priority value here means the
    same thing as an identical priority value in $(D core.thread).

    Note:  For a size zero pool, the getter arbitrarily returns
           $(D core.thread.Thread.PRIORITY_MIN) and the setter has no effect.
    */
    int priority() @property @trusted {
        return (size == 0) ? core.thread.Thread.PRIORITY_MIN :
                             pool[0].priority();
    }

    /// Ditto
    void priority(int newPriority) @property @trusted {
        if(size > 0) {
            foreach(t; pool) {
                t.priority(newPriority);
            }
        }
    }
}

/**
Returns a lazily initialized global instantiation of $(D TaskPool).
This function can safely be called concurrently from multiple non-worker
threads.  The worker threads in this pool are daemon threads, meaning that it
is not necessary to call $(D TaskPool.stop) or $(D TaskPool.finish) before
terminating the main thread.
*/
 @property TaskPool taskPool() @trusted {
    static bool initialized;
    __gshared static TaskPool pool;

    if(!initialized) {
        synchronized {
            if(!pool) {
                pool = new TaskPool(defaultPoolThreads);
                pool.isDaemon = true;
            }
        }

        initialized = true;
    }

    return pool;
}

private shared uint _defaultPoolThreads;
shared static this() {
    cas(&_defaultPoolThreads, _defaultPoolThreads, totalCPUs - 1U);
}

/**
These properties get and set the number of worker threads in the $(D TaskPool)
instance returned by $(D taskPool).  The default value is $(D totalCPUs) - 1.
Calling the setter after the first call to $(D taskPool) does not changes
number of worker threads in the instance returned by $(D taskPool).
*/
@property uint defaultPoolThreads() @trusted {
    // Kludge around lack of atomic load.
    return atomicOp!"+"(_defaultPoolThreads, 0U);
}

/// Ditto
@property void defaultPoolThreads(uint newVal) @trusted {
    cas(&_defaultPoolThreads, _defaultPoolThreads, newVal);
}

/**
Convenience functions that forwards to $(D taskPool.parallel).  The
purpose of these is to make parallel foreach less verbose and more
readable.

Example:
---
// Find the logarithm of every number from 1 to 1_000_000 in parallel,
// using the default TaskPool instance.
auto logs = new double[1_000_000];

foreach(i, ref elem; parallel(logs)) {
    elem = log(i + 1.0);
}
---

*/
ParallelForeach!R parallel(R)(R range) {
    return taskPool.parallel(range);
}

/// Ditto
ParallelForeach!R parallel(R)(R range, size_t workUnitSize) {
    return taskPool.parallel(range, workUnitSize);
}

// Thrown when a parallel foreach loop is broken from.
class ParallelForeachError : Error {
    this() {
        super("Cannot break from a parallel foreach loop using break, return, "
              ~ "labeled break/continue or goto statements.");
    }
}

private void foreachErr() { throw new ParallelForeachError(); }

private struct ParallelForeachTask(R, Delegate)
if(isRandomAccessRange!R && hasLength!R) {
    enum withIndex = ParameterTypeTuple!(Delegate).length == 2;

    static void impl(void* myTask) {
        auto myCastedTask = cast(ParallelForeachTask!(R, Delegate)*) myTask;
        foreach(i; myCastedTask.lowerBound..myCastedTask.upperBound) {

            static if(hasLvalueElements!R) {
                static if(withIndex) {
                    if(myCastedTask.runMe(i, myCastedTask.myRange[i])) foreachErr();
                } else {
                    if(myCastedTask.runMe( myCastedTask.myRange[i])) foreachErr();
                }
            } else {
                auto valToPass = myCastedTask.myRange[i];
                static if(withIndex) {
                    if(myCastedTask.runMe(i, valToPass)) foreachErr();
                } else {
                    if(myCastedTask.runMe(valToPass)) foreachErr();
                }
            }
        }

        // Allow some memory reclamation.
        myCastedTask.myRange = R.init;
        myCastedTask.runMe = null;
    }

    mixin BaseMixin!(TaskState.done);

    TaskPool pool;

    // More specific stuff.
    size_t lowerBound;
    size_t upperBound;
    R myRange;
    Delegate runMe;

    void force() {
        if(pool is null) {
            // Never submitted.  No need to force.
            return;
        }

        pool.lock();
        scope(exit) pool.unlock();

        // No work stealing here b/c the function that waits on this task
        // wants to recycle it as soon as it finishes.
        while(!done()) {
            pool.waitUntilCompletion();
        }

        if(exception) {
            throw exception;
        }
    }
}

private struct ParallelForeachTask(R, Delegate)
if(!isRandomAccessRange!R || !hasLength!R) {
    enum withIndex = ParameterTypeTuple!(Delegate).length == 2;

    static void impl(void* myTask) {
        auto myCastedTask = cast(ParallelForeachTask!(R, Delegate)*) myTask;

        static ref ElementType!(R) getElement(T)(ref T elemOrPtr) {
            static if(is(typeof(*elemOrPtr) == ElementType!R)) {
                return *elemOrPtr;
            } else {
                return elemOrPtr;
            }
        }

        foreach(i, element; myCastedTask.elements) {
            static if(withIndex) {
                size_t lValueIndex = i + myCastedTask.startIndex;
                if(myCastedTask.runMe(lValueIndex, getElement(element))) foreachErr();
            } else {
                if(myCastedTask.runMe(getElement(element))) foreachErr();
            }
        }

        // Make memory easier to reclaim.
        myCastedTask.runMe = null;
    }

    mixin BaseMixin!(TaskState.done);

    TaskPool pool;

    // More specific stuff.
    alias ElementType!R E;
    Delegate runMe;

    static if(hasLvalueElements!(R)) {
        E*[] elements;
    } else {
        E[] elements;
    }
    size_t startIndex;

    void force() {
        if(pool is null) {
            // Never submitted.  No need to force.
            return;
        }

        pool.lock();
        scope(exit) pool.unlock();

        // Don't try to execute in this thread b/c the function that waits on
        // this task wants to recycle it as soon as it finishes.

        while(!done()) {
            pool.waitUntilCompletion();
        }

        if(exception) {
            throw exception;
        }
    }
}

private struct MapTask(alias fun, R, ReturnType)
if(isRandomAccessRange!R && hasLength!R) {
    static void impl(void* myTask) {
        auto myCastedTask = cast(MapTask!(fun, R, ReturnType)*) myTask;

        foreach(i; myCastedTask.lowerBound..myCastedTask.upperBound) {
            myCastedTask.results[i] = uFun(myCastedTask.range[i]);
        }

        // Nullify stuff, make GC's life easier.
        myCastedTask.results = null;
        myCastedTask.range = R.init;
    }

    mixin BaseMixin!(TaskState.done);

    TaskPool pool;

    // More specific stuff.
    alias unaryFun!fun uFun;
    R range;
    alias ElementType!R E;
    ReturnType results;
    size_t lowerBound;
    size_t upperBound;

    void force() {
        if(pool is null) {
            // Never submitted.  No need to force it.
            return;
        }

        pool.lock();
        scope(exit) pool.unlock();

         while(!done()) {
            pool.waitUntilCompletion();
        }

        if(exception) {
            throw exception;
        }
    }
}

// This mixin causes rethrown exceptions to be caught and chained.  It's used
// in parallel amap and foreach.
private enum parallelExceptionHandling = q{
    try {
        // Calling done() rethrows exceptions.
        if(!task.done) {
            continue;
        }
    } catch(Throwable e) {
        firstException = e;
        lastException = findLastException(e);
        task.exception = null;
        atomicSetUbyte(doneSubmitting, 1);
        return;
    }
};

// This mixin causes tasks to be submitted lazily to
// the task pool.  Attempts are then made by the calling thread to execute
// them.  It's used in parallel amap and foreach.
private enum submitAndExecute = q{

    // See documentation for BaseMixin.shouldSetDone.
    submitNextBatch.shouldSetDone = false;

    // Submit first batch from this thread.
    submitJobs();

    while( !atomicReadUbyte(doneSubmitting) ) {
        // Try to do parallel foreach tasks in this thread.
        foreach(ref task; tasks) {
            pool.tryDeleteExecute( cast(AbstractTask*) &task);
        }

        // All tasks in progress or done unless next/ submission task started
        // running.  Try to execute the submission task.
        pool.tryDeleteExecute(cast(AbstractTask*) &submitNextBatch);
    }

    // Try to execute one last time, after they're all submitted.
    foreach(ref task; tasks) {
        pool.tryDeleteExecute( cast(AbstractTask*) &task);
    }

    foreach(ref task; tasks) {
        try {
            task.force();
        } catch(Throwable e) {
            addToChain(e, firstException, lastException);
        }
    }

    if(firstException) throw firstException;
};

/*------Structs that implement opApply for parallel foreach.------------------*/
private template randLen(R) {
    enum randLen = isRandomAccessRange!R && hasLength!R;
}

private enum string parallelApplyMixin = q{
    alias ParallelForeachTask!(R, typeof(dg)) PTask;

    // Handle empty thread pool as special case.
    if(pool.size == 0) {
        int res = 0;
        size_t index = 0;

        // The explicit ElementType!R in the foreach loops is necessary for
        // correct behavior when iterating over strings.
        static if(hasLvalueElements!(R)) {
            foreach(ref ElementType!R elem; range) {
                static if(ParameterTypeTuple!(dg).length == 2) {
                    res = dg(index, elem);
                } else {
                    res = dg(elem);
                }
                index++;
            }
        } else {
            foreach(ElementType!R elem; range) {
                static if(ParameterTypeTuple!(dg).length == 2) {
                    res = dg(index, elem);
                } else {
                    res = dg(elem);
                }
                index++;
            }
        }
        return res;
    }

    Throwable firstException, lastException;

    PTask[] tasks = (cast(PTask*) alloca(pool.size * PTask.sizeof * 2))
                    [0..pool.size * 2];
    tasks[] = PTask.init;
    Task!(run, void delegate()) submitNextBatch;

    static if(is(typeof(range.buf1)) && is(typeof(range.bufPos)) &&
    is(typeof(range.doBufSwap()))) {
        enum bool bufferTrick = true;

        version(unittest) {
            pragma(msg, "Parallel Foreach Buffer Trick:  " ~ R.stringof);
        }

    } else {
        enum bool bufferTrick = false;
    }

    static if(randLen!R) {

        immutable size_t len = range.length;
        size_t curPos = 0;

        void useTask(ref PTask task) {
            task.lowerBound = curPos;
            task.upperBound = min(len, curPos + blockSize);
            task.myRange = range;
            task.runMe = dg;
            task.pool = pool;
            curPos += blockSize;

            pool.lock();
            atomicSetUbyte(task.taskStatus, TaskState.notStarted);
            pool.abstractPutNoSync(cast(AbstractTask*) &task);
            pool.unlock();
        }

        bool emptyCheck() {
            return curPos >= len;
        }
    } else {

        static if(bufferTrick) {
            blockSize = range.buf1.length;
        }

        void useTask(ref PTask task) {
            task.runMe = dg;
            task.pool = pool;

            static if(bufferTrick) {
                // Elide copying by just swapping buffers.
                task.elements.length = range.buf1.length;
                swap(range.buf1, task.elements);

                static if(is(typeof(range._length))) {
                    range._length -= (task.elements.length - range.bufPos);
                }

                range.doBufSwap();

            } else {
                size_t copyIndex = 0;

                if(task.elements.length == 0) {
                    task.elements.length = blockSize;
                }

                for(; copyIndex < blockSize && !range.empty; copyIndex++) {
                    static if(hasLvalueElements!R) {
                        task.elements[copyIndex] = &range.front();
                    } else {
                        task.elements[copyIndex] = range.front;
                    }
                    range.popFront;
                }

                // We only actually change the array  size on the last task,
                // when the range is empty.
                task.elements = task.elements[0..copyIndex];
            }

            pool.lock();
            task.startIndex = this.startIndex;
            this.startIndex += task.elements.length;
            atomicSetUbyte(task.taskStatus, TaskState.notStarted);
            pool.abstractPutNoSync(cast(AbstractTask*) &task);
            pool.unlock();
        }

        bool emptyCheck() {
            return range.empty;
        }
    }

    // This has to be down here to work around forward reference issues.
    void submitJobs() {
        // Search for slots to recycle.
        foreach(ref task; tasks) {
            mixin(parallelExceptionHandling);

            useTask(task);
            if(emptyCheck()) {
                atomicSetUbyte(doneSubmitting, 1);
                return;
            }
        }

        // Now that we've submitted all the worker tasks, submit
        // the next submission task.  Synchronizing on the pool
        // to prevent the stealing thread from deleting the job
        // before it's submitted.
        pool.lock();
        atomicSetUbyte(submitNextBatch.taskStatus, TaskState.notStarted);
        pool.abstractPutNoSync( cast(AbstractTask*) &submitNextBatch);
        pool.unlock();
    }

    submitNextBatch = scopedTask(&submitJobs);

    mixin(submitAndExecute);

    return 0;
};

// Calls e.next until the end of the chain is found.
private Throwable findLastException(Throwable e) pure nothrow {
    if(e is null) return null;

    while(e.next) {
        e = e.next;
    }

    return e;
}

// Adds e to the exception chain.
private void addToChain(
    Throwable e,
    ref Throwable firstException,
    ref Throwable lastException
) pure nothrow {
    if(firstException) {
        assert(lastException);
        lastException.next = e;
        lastException = findLastException(e);
    } else {
        firstException = e;
        lastException = findLastException(e);
    }
}

private struct ParallelForeach(R) {
    TaskPool pool;
    R range;
    size_t blockSize;
    size_t startIndex;
    ubyte doneSubmitting;

    alias ElementType!R E;

    int opApply(scope int delegate(ref E) dg) {
        mixin(parallelApplyMixin);
    }

    int opApply(scope int delegate(ref size_t, ref E) dg) {
        mixin(parallelApplyMixin);
    }
}

version(unittest) {
    // This was the only way I could get nested maps to work.
    __gshared TaskPool poolInstance;
}

// These test basic functionality but don't stress test for threading bugs.
// These are the tests that should be run every time Phobos is compiled.
unittest {
    poolInstance = new TaskPool(2);

    auto oldPriority = poolInstance.priority;
    poolInstance.priority = Thread.PRIORITY_MAX;
    assert(poolInstance.priority == Thread.PRIORITY_MAX);

    poolInstance.priority = Thread.PRIORITY_MIN;
    assert(poolInstance.priority == Thread.PRIORITY_MIN);

    poolInstance.priority = oldPriority;
    assert(poolInstance.priority == oldPriority);

    scope(exit) poolInstance.stop;

    static void refFun(ref uint num) {
        num++;
    }

    uint x;

    // Test task().
    auto t = task!refFun(x);
    poolInstance.put(t);
    t.yieldForce();
    assert(t.args[0] == 1);

    auto t2 = task(&refFun, x);
    poolInstance.put(t2);
    t2.yieldForce();
    assert(t2.args[0] == 1);

    // Test scopedTask().
    auto st = scopedTask!refFun(x);
    poolInstance.put(st);
    st.yieldForce();
    assert(st.args[0] == 1);

    auto st2 = scopedTask(&refFun, x);
    poolInstance.put(st2);
    st2.yieldForce();
    assert(st2.args[0] == 1);

    // Test executeInNewThread().
    auto ct = scopedTask!refFun(x);
    ct.executeInNewThread();
    ct.yieldForce();
    assert(ct.args[0] == 1);

    // Test ref return.
    uint toInc = 0;
    static ref T makeRef(T)(ref T num) {
        return num;
    }

    auto t3 = task!makeRef(toInc);
    taskPool.put(t3);//.submit;
    assert(t3.args[0] == 0);
    t3.spinForce++;
    assert(t3.args[0] == 1);

    static void testSafe() @safe {
        static int bump(int num) {
            return num + 1;
        }

        auto safePool = new TaskPool(0);
        auto t = task(&bump, 1);
        taskPool.put(t);
        assert(t.yieldForce == 2);
        safePool.stop;
    }

    auto arr = [1,2,3,4,5];
    auto appNums = appender!(uint[])();
    auto appNums2 = appender!(uint[])();
    foreach(i, ref elem; poolInstance.parallel(arr)) {
        elem++;
        synchronized {
            appNums.put(cast(uint) i + 2);
            appNums2.put(elem);
        }
    }

    uint[] nums = appNums.data, nums2 = appNums2.data;
    sort!"a.at!0 < b.at!0"(zip(nums, nums2));
    assert(nums == [2,3,4,5,6]);
    assert(nums2 == nums);
    assert(arr == nums);

    // Test parallel foreach with non-random access range.
    nums = null;
    nums2 = null;
    auto range = filter!"a != 666"([0, 1, 2, 3, 4]);
    foreach(i, elem; poolInstance.parallel(range)) {
        synchronized {
            nums ~= cast(uint) i;
            nums2 ~= cast(uint) i;
        }
    }

    sort!"a.at!0 < b.at!0"(zip(nums, nums2));
    assert(nums == nums2);
    assert(nums == [0,1,2,3,4]);


    assert(poolInstance.amap!"a * a"([1,2,3,4,5]) == [1,4,9,16,25]);
    assert(poolInstance.amap!"a * a"([1,2,3,4,5], new long[5]) == [1,4,9,16,25]);
    assert(poolInstance.amap!("a * a", "-a")([1,2,3]) ==
        [tuple(1, -1), tuple(4, -2), tuple(9, -3)]);

    auto tupleBuf = new Tuple!(int, int)[3];
    poolInstance.amap!("a * a", "-a")([1,2,3], tupleBuf);
    assert(tupleBuf == [tuple(1, -1), tuple(4, -2), tuple(9, -3)]);
    poolInstance.amap!("a * a", "-a")([1,2,3], 5, tupleBuf);
    assert(tupleBuf == [tuple(1, -1), tuple(4, -2), tuple(9, -3)]);

    auto buf = new int[5];
    poolInstance.amap!"a * a"([1,2,3,4,5], buf);
    assert(buf == [1,4,9,16,25]);
    poolInstance.amap!"a * a"([1,2,3,4,5], 4, buf);
    assert(buf == [1,4,9,16,25]);


    assert(poolInstance.reduce!"a + b"([1,2,3,4]) == 10);
    assert(poolInstance.reduce!"a + b"(0.0, [1,2,3,4]) == 10);
    assert(poolInstance.reduce!"a + b"(0.0, [1,2,3,4], 1) == 10);
    assert(poolInstance.reduce!(min, max)([1,2,3,4]) == tuple(1, 4));
    assert(poolInstance.reduce!("a + b", "a * b")(tuple(0, 1), [1,2,3,4]) ==
        tuple(10, 24));

    // Test worker-local storage.
    auto wl = poolInstance.workerLocalStorage(0);
    foreach(i; poolInstance.parallel(iota(1000), 1)) {
        wl.get = wl.get + i;
    }

    auto wlRange = wl.toRange;
    auto parallelSum = poolInstance.reduce!"a + b"(wlRange);
    assert(parallelSum == 499500);
    assert(wlRange[0..1][0] == wlRange[0]);
    assert(wlRange[1..2][0] == wlRange[1]);

    // Test default pool stuff.
    assert(taskPool.size == totalCPUs - 1);

    nums = null;
    foreach(i; parallel(iota(1000))) {
        synchronized {
            nums ~= i;
        }
    }
    sort(nums);
    assert(equal(nums, iota(1000)));

    assert(equal(
        poolInstance.map!"a * a"(iota(30_000_001), 10_000, 1000),
        std.algorithm.map!"a * a"(iota(30_000_001))
    ));

    // The filter is to kill random access and test the non-random access
    // branch.
    assert(equal(
        poolInstance.map!"a * a"(
            filter!"a == a"(iota(30_000_001)
        ), 10_000, 1000),
        std.algorithm.map!"a * a"(iota(30_000_001))
    ));

    assert(
        reduce!"a + b"(0UL,
            poolInstance.map!"a * a"(iota(3_000_001), 10_000)
        ) ==
        reduce!"a + b"(0UL,
            std.algorithm.map!"a * a"(iota(3_000_001))
        )
    );

    assert(equal(
        iota(1_000_002),
        poolInstance.asyncBuf(filter!"a == a"(iota(1_000_002)))
    ));

    // Test LazyMap/AsyncBuf chaining.
    auto lmchain = poolInstance.map!"a * a"(
        poolInstance.map!sqrt(
            poolInstance.asyncBuf(
                iota(3_000_000)
            )
        )
    );

    foreach(i, elem; parallel(lmchain)) {
        assert(approxEqual(elem, i));
    }

    auto myTask = task!(std.math.abs)(-1);
    taskPool.put(myTask);
    assert(myTask.spinForce == 1);

    // Test that worker local storage from one pool receives an index of 0
    // when the index is queried w.r.t. another pool.  The only way to do this
    // is non-deterministically.
    foreach(i; parallel(iota(1000), 1)) {
        assert(poolInstance.workerIndex == 0);
    }

    foreach(i; poolInstance.parallel(iota(1000), 1)) {
        assert(taskPool.workerIndex == 0);
    }
}

version = parallelismStressTest;

// These are more like stress tests than real unit tests.  They print out
// tons of stuff and should not be run every time make unittest is run.
version(parallelismStressTest) {
    // These unittests are intended to also function as an example of how to
    // use this module.
    unittest {
        size_t attempt;
        for(; attempt < 10; attempt++)
        foreach(poolSize; [0, 4]) {

            // Create a TaskPool object with the default number of threads.
            poolInstance = new TaskPool(poolSize);

            // Create some data to work on.
            uint[] numbers = new uint[1_000];

            // Fill in this array in parallel, using default block size.
            // Note:  Be careful when writing to adjacent elements of an arary from
            // different threads, as this can cause word tearing bugs when
            // the elements aren't properly aligned or aren't the machine's native
            // word size.  In this case, though, we're ok.
            foreach(i; poolInstance.parallel( iota(0, numbers.length)) ) {
                numbers[i] = cast(uint) i;
            }

            // Make sure it works.
            foreach(i; 0..numbers.length) {
                assert(numbers[i] == i);
            }

            stderr.writeln("Done creating nums.");

            // Parallel foreach also works on non-random access ranges, albeit
            // less efficiently.
            auto myNumbers = filter!"a % 7 > 0"( iota(0, 1000));
            foreach(num; poolInstance.parallel(myNumbers)) {
                assert(num % 7 > 0 && num < 1000);
            }
            stderr.writeln("Done modulus test.");

            // Use parallel amap to calculate the square of each element in numbers,
            // and make sure it's right.
            uint[] squares = poolInstance.amap!"a * a"(numbers, 100);
            assert(squares.length == numbers.length);
            foreach(i, number; numbers) {
                assert(squares[i] == number * number);
            }
            stderr.writeln("Done squares.");

            // Sum up the array in parallel with the current thread.
            auto sumFuture = task!( reduce!"a + b" )(numbers);
            poolInstance.put(sumFuture);

            // Go off and do other stuff while that future executes:
            // Find the sum of squares of numbers.
            ulong sumSquares = 0;
            foreach(elem; numbers) {
                sumSquares += elem * elem;
            }

            // Ask for our result.  If the pool has not yet started working on
            // this task, spinForce() automatically steals it and executes it in this
            // thread.
            uint mySum = sumFuture.spinForce();
            assert(mySum == 999 * 1000 / 2);

            // We could have also computed this sum in parallel using parallel
            // reduce.
            auto mySumParallel = poolInstance.reduce!"a + b"(numbers);
            assert(mySum == mySumParallel);
            stderr.writeln("Done sums.");

            // Execute an anonymous delegate as a task.
            auto myTask = task({
                synchronized writeln("Our lives are parallel...Our lives are parallel.");
            });
            poolInstance.put(myTask);

            // Parallel foreach loops can also be nested, and can have an index
            // variable attached to the foreach loop.
            auto nestedOuter = "abcd";
            auto nestedInner =  iota(0, 10, 2);

            foreach(i, letter; poolInstance.parallel(nestedOuter, 1)) {
                foreach(j, number; poolInstance.parallel(nestedInner, 1)) {
                    synchronized writeln
                        (i, ": ", letter, "  ", j, ": ", number);
                }
            }

            poolInstance.stop();
        }

        assert(attempt == 10);
        writeln("Press enter to go to next round of unittests.");
        readln();
    }

    // These unittests are intended more for actual testing and not so much
    // as examples.
    unittest {
        foreach(attempt; 0..10)
        foreach(poolSize; [0, 4]) {
            poolInstance = new TaskPool(poolSize);

            // Test indexing.
            stderr.writeln("Creator Raw Index:  ", poolInstance.threadIndex);
            assert(poolInstance.workerIndex() == 0);

            // Test worker-local storage.
            auto workerLocalStorage = poolInstance.workerLocalStorage!(uint)(1);
            foreach(i; poolInstance.parallel(iota(0U, 1_000_000))) {
                workerLocalStorage.get++;
            }
            assert(reduce!"a + b"(workerLocalStorage.toRange) ==
                1_000_000 + poolInstance.size + 1);

            // Make sure work is reasonably balanced among threads.  This test is
            // non-deterministic and is more of a sanity check than something that
            // has an absolute pass/fail.
            uint[void*] nJobsByThread;
            foreach(thread; poolInstance.pool) {
                nJobsByThread[cast(void*) thread] = 0;
            }
            nJobsByThread[ cast(void*) Thread.getThis] = 0;

            foreach(i; poolInstance.parallel( iota(0, 1_000_000), 100 )) {
                atomicIncUint( nJobsByThread[ cast(void*) Thread.getThis() ]);
            }

            stderr.writeln("\nCurrent (stealing) thread is:  ",
                cast(void*) Thread.getThis());
            stderr.writeln("Workload distribution:  ");
            foreach(k, v; nJobsByThread) {
                stderr.writeln(k, '\t', v);
            }

            // Test whether amap can be nested.
            real[][] matrix = new real[][](1000, 1000);
            foreach(i; poolInstance.parallel( iota(0, matrix.length) )) {
                foreach(j; poolInstance.parallel( iota(0, matrix[0].length) )) {
                    matrix[i][j] = i * j;
                }
            }

            // Get around weird bugs having to do w/ sqrt being an intrinsic:
            static real mySqrt(real num) {
                return sqrt(num);
            }

            static real[] parallelSqrt(real[] nums) {
                return poolInstance.amap!mySqrt(nums);
            }

            real[][] sqrtMatrix = poolInstance.amap!parallelSqrt(matrix);

            foreach(i, row; sqrtMatrix) {
                foreach(j, elem; row) {
                    real shouldBe = sqrt( cast(real) i * j);
                    assert(approxEqual(shouldBe, elem));
                    sqrtMatrix[i][j] = shouldBe;
                }
            }

            auto saySuccess = task({
                stderr.writeln(
                    "Success doing matrix stuff that involves nested pool use.");
            });
            poolInstance.put(saySuccess);
            saySuccess.workForce();

            // A more thorough test of amap, reduce:  Find the sum of the square roots of
            // matrix.

            static real parallelSum(real[] input) {
                return poolInstance.reduce!"a + b"(input);
            }

            auto sumSqrt = poolInstance.reduce!"a + b"(
                poolInstance.amap!parallelSum(
                    sqrtMatrix
                )
            );

            assert(approxEqual(sumSqrt, 4.437e8));
            stderr.writeln("Done sum of square roots.");

            // Test whether tasks work with function pointers.
            auto nanTask = task(&isNaN, 1.0L);
            poolInstance.put(nanTask);
            assert(nanTask.spinForce == false);

            if(poolInstance.size > 0) {
                // Test work waiting.
                static void uselessFun() {
                    foreach(i; 0..1_000_000) {}
                }

                auto uselessTasks = new typeof(task(&uselessFun))[1000];
                foreach(ref uselessTask; uselessTasks) {
                    uselessTask = task(&uselessFun);
                }
                foreach(ref uselessTask; uselessTasks) {
                    poolInstance.put(uselessTask);
                }
                foreach(ref uselessTask; uselessTasks) {
                    uselessTask.workForce();
                }
            }

            // Test the case of non-random access + ref returns.
            int[] nums = [1,2,3,4,5];
            static struct RemoveRandom {
                int[] arr;

                ref int front() { return arr.front; }
                void popFront() { arr.popFront(); }
                bool empty() { return arr.empty; }
            }

            auto refRange = RemoveRandom(nums);
            foreach(ref elem; poolInstance.parallel(refRange)) {
                elem++;
            }
            assert(nums == [2,3,4,5,6]);
            stderr.writeln("Nums:  ", nums);

            poolInstance.stop();
        }
    }
}

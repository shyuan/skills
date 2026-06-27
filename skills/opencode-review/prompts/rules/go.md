#### Obvious Typos or Spelling Errors
- Spelling errors in type names, function names, variable names, struct field names, or package names at their declaration sites; do not report spelling errors at call sites
- Strings in log messages, error messages, panic messages, or public diagnostics containing spelling errors that affect readability
- Exported identifiers whose doc comment does not begin with the identifier name, when the package otherwise follows that convention

#### Error Handling
- Errors that are ignored via `_` or dropped entirely where the failure is actionable; a returned `error` must be checked or deliberately and visibly discarded
- Errors returned without context where wrapping with `fmt.Errorf("...: %w", err)` would aid debugging; conversely, double-wrapping or wrapping that leaks internal detail across an API boundary
- Use of `errors.Is` / `errors.As` versus fragile string matching on `err.Error()`; sentinel errors compared with `==` after the error has been wrapped
- `panic` used for ordinary recoverable conditions in library code instead of returning an error; missing `recover` only where a goroutine panic would crash the whole process
- Error values constructed but not returned (e.g. `errors.New(...)` whose result is discarded), or `err` shadowed by `:=` in an inner scope so the outer check never sees it

#### Goroutines and Concurrency
- Goroutines with no clear termination path — leaks from missing `context` cancellation, unconsumed channels, or `WaitGroup` that is never `Done`
- `WaitGroup.Add` called inside the goroutine instead of before it; `wg.Done` not deferred so an early return or panic skips it
- Data races: shared maps, slices, or struct fields written from multiple goroutines without a `sync.Mutex`, channel, or atomic; loop variables captured by reference in goroutines (pre-1.22 semantics) when the code may run on older toolchains
- Channels: send on a closed channel, close from the receiver side, double close, or nil-channel operations that block forever; unbuffered channels used where the sender can outlive the receiver
- `sync.Mutex` held across blocking calls, I/O, or calls into user code; `defer mu.Unlock()` missing on an early-return path; copying a struct that contains a `sync.Mutex` (locks must not be copied)
- Check-then-act races around cache initialization, file creation, or map access where `sync.Once` or a single guarded section is needed

#### Context Usage
- `context.Context` not threaded through to blocking I/O, network, or DB calls, so cancellation and deadlines are not honored
- `context.Background()` or `context.TODO()` used in a request/worker path where an incoming context exists and should be propagated
- Context stored in a struct field instead of being passed as the first argument; values smuggled through `context.WithValue` for data that belongs in explicit parameters
- A derived context's `cancel` function not called (e.g. `WithTimeout`/`WithCancel` whose `cancel` is dropped), leaking the timer/goroutine

#### Nil, Slices, and Maps
- Writing to a nil map (panics) — a map returned or stored must be made with `make` before assignment
- Assuming a nil slice and an empty slice behave identically where length, JSON marshaling (`null` vs `[]`), or append aliasing actually differs
- `append` aliasing bugs: appending to a re-sliced slice that shares backing array with another live slice, silently overwriting data
- Nil pointer dereference from a function that can return `(nil, nil)` or a typed-nil interface (`var p *T = nil; var i I = p; i != nil` is true)
- Index or slice expressions without bounds reasoning when the length comes from external input

#### Resource Management
- `defer` for cleanup missing, so `Close`/`Unlock`/`cancel` is skipped on error paths; `defer` inside a loop accumulating resources until the function returns instead of closing each iteration
- `Close` errors ignored on writable resources (files, writers, flushers) where a failed flush means data loss
- HTTP response bodies not closed (`resp.Body.Close()`), or not drained before close, preventing connection reuse
- `os.Open`/`sql.Rows`/`http.Response` and similar leaked when an early return happens before the deferred close is registered

#### Performance and Allocation
- Avoidable allocations in hot paths: repeated string concatenation in a loop where `strings.Builder` or a preallocated buffer is clearer, or `fmt.Sprintf` for trivial concatenation
- Slices and maps not preallocated with a known capacity (`make([]T, 0, n)`), causing repeated growth in tight loops
- O(n^2) work from nested loops where a `map` lookup, sort, or index would clearly reduce complexity
- Unnecessary conversions between `[]byte` and `string` in hot paths; defensive copies that are not needed
- Database or network calls inside a loop (N+1) where batching is available

#### API and Type Design
- Exported functions returning concrete unexported types, or accepting concrete types where a small interface defined at the consumer would decouple the call site
- Interfaces defined at the producer with many methods when consumers need only one or two ("accept interfaces, return structs")
- Boolean or string parameters encoding state that would be safer as a typed constant / enum, allowing invalid combinations to be representable
- Returning bare `error` from a constructor that has already allocated resources without cleaning them up on the failure path
- Mutable package-level state and `init()` side effects that make behavior order-dependent or hard to test

#### Security-Sensitive Code
- Building SQL, shell commands, file paths, or URLs via unchecked string concatenation; prefer parameterized queries, `exec.Command` with separate args, and `filepath.Clean` plus a base-dir check against traversal
- Logging secrets, tokens, credentials, private keys, or personally identifiable information
- Integer conversions and length arithmetic that can overflow or truncate, especially when narrowing from `int`/`int64` to a smaller type on untrusted input
- Use of `math/rand` for security-sensitive values where `crypto/rand` is required; ad hoc crypto instead of `crypto/*` standard packages
- Missing validation of deserialized input (JSON/YAML/protobuf) before it is trusted, and unbounded reads (`io.ReadAll` on an untrusted body without a limit)

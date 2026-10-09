# Telemetry

Licet emits [`:telemetry`](https://hexdocs.pm/telemetry) events for checks, lookups, writes, and the check cache. Attach handlers to them to export metrics or log slow queries.

## Span events

Checks, lookups, and writes are wrapped in `:telemetry.span/3`. Each emits a `:start` event, then either `:stop` or `:exception`:

| Event prefix | Emitted by | Metadata |
| --- | --- | --- |
| `[:licet, :check]` | `Licet.check/5` | `:resource`, `:permission`, `:subject` |
| `[:licet, :lookup]` | `Licet.lookup_resources/5` | `:resource_type`, `:permission`, `:subject` |
| `[:licet, :lookup]` | `Licet.lookup_subjects/5` | `:resource`, `:permission`, `:subject_type` |
| `[:licet, :write]` | `Licet.write/3`, `Licet.import/3` | `:count`, the number of updates |

Measurements follow the `:telemetry.span/3` convention:

* `:start` has `:system_time` and `:monotonic_time`.
* `:stop` has `:duration` and `:monotonic_time`.
* `:exception` has `:duration` and `:monotonic_time`, and its metadata adds `:kind`, `:reason`, and `:stacktrace`.

Durations are in native time units. Convert them with `System.convert_time_unit/3`.

A check that returns `{:error, _}` still ends with a `:stop` event. `:exception` is emitted only when the call raises.

`Licet.check_bulk/3` doesn't emit per-item check events.

## Cache events

Each check outside a transaction first looks in the cache:

| Event | Measurements | Metadata |
| --- | --- | --- |
| `[:licet, :cache, :hit]` | `%{count: 1}` | `%{}` |
| `[:licet, :cache, :miss]` | `%{count: 1}` | `%{}` |

Checks inside a transaction and checks with `consistency: :full` skip the cache and emit neither event.

## Metrics

With [`telemetry_metrics`](https://hexdocs.pm/telemetry_metrics), for example in your application's telemetry supervisor:

```elixir
import Telemetry.Metrics

[
  summary("licet.check.stop.duration", unit: {:native, :millisecond}),
  summary("licet.lookup.stop.duration", unit: {:native, :millisecond}),
  summary("licet.write.stop.duration", unit: {:native, :millisecond}),
  sum("licet.write.stop.count", measurement: fn _measurements, metadata -> metadata.count end),
  counter("licet.cache.hit.count"),
  counter("licet.cache.miss.count")
]
```

## Logging slow checks

```elixir
:telemetry.attach(
  "licet-slow-checks",
  [:licet, :check, :stop],
  fn _event, %{duration: duration}, metadata, _config ->
    ms = System.convert_time_unit(duration, :native, :millisecond)

    if ms > 50 do
      Logger.warning("slow Licet check: #{ms}ms #{inspect(metadata)}")
    end
  end,
  nil
)
```

Use a module function instead of an anonymous function in production, as the `:telemetry` documentation recommends.

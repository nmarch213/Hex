import { Effect, Fiber, FiberSet, Ref, Schema } from "effect"

/** Reports that another authenticated request already owns the audio-body slot. */
export class InboundAudioBusyError extends Schema.TaggedError<InboundAudioBusyError>()(
  "InboundAudioBusyError",
  { retryAfterSeconds: Schema.Number }
) {}

/** Owns fail-fast admission for the single in-memory authenticated audio body. */
export class InboundAudioAdmission extends Effect.Service<InboundAudioAdmission>()(
  "@hex/personal-dictation/InboundAudioAdmission",
  {
    scoped: Effect.gen(function* () {
      const active = yield* Ref.make(false)
      const workers = yield* FiberSet.make()
      const acquire = Ref.modify(
        active,
        (isActive): readonly [boolean, boolean] =>
          isActive ? [false, true] : [true, true]
      ).pipe(
        Effect.flatMap((acquired) =>
          acquired
            ? Effect.void
            : Effect.fail(
                new InboundAudioBusyError({ retryAfterSeconds: 1 })
              )
        )
      )

      const run = <A, E, R>(
        operation: Effect.Effect<A, E, R>
      ): Effect.Effect<A, E | InboundAudioBusyError, R> =>
        Effect.uninterruptibleMask((restore) =>
          Effect.gen(function* () {
            yield* acquire
            const worker = yield* FiberSet.run(
              workers,
              operation.pipe(
                Effect.ensuring(Ref.set(active, false)),
                Effect.interruptible
              )
            )
            return yield* restore(Fiber.join(worker))
          })
        )

      return { run }
    })
  }
) {}

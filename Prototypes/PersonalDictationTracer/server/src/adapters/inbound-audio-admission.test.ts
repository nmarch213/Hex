import assert from "node:assert/strict"
import test from "node:test"

import { Deferred, Effect, Fiber } from "effect"

import {
  InboundAudioAdmission,
  InboundAudioBusyError
} from "./inbound-audio-admission.js"

test("retains admission until a supervised body worker ends after waiter cancellation", async () => {
  await Effect.runPromise(
    Effect.gen(function* () {
      const admission = yield* InboundAudioAdmission
      const started = yield* Deferred.make<void>()
      const finish = yield* Deferred.make<void>()
      const workerFinished = yield* Deferred.make<void>()

      const waiter = yield* admission.run(
        Deferred.succeed(started, undefined).pipe(
          Effect.zipRight(Deferred.await(finish)),
          Effect.ensuring(Deferred.succeed(workerFinished, undefined))
        )
      ).pipe(Effect.fork)

      yield* Deferred.await(started)
      yield* Fiber.interrupt(waiter)

      const overlapping = yield* Effect.flip(admission.run(Effect.void))
      assert.equal(overlapping instanceof InboundAudioBusyError, true)

      yield* Deferred.succeed(finish, undefined)
      yield* Deferred.await(workerFinished)
      yield* Effect.yieldNow()
      yield* admission.run(Effect.void)
    }).pipe(
      Effect.provide(InboundAudioAdmission.Default),
      Effect.scoped
    )
  )
})

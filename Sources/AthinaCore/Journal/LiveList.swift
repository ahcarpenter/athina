import Foundation

/// Hands `deliver` each list a live query delivers, until the calling task is
/// cancelled.
///
/// A live query ends at its first failed fetch, so when one fails this tells
/// `restarting` why, waits `backOff` on `clock` and follows a fresh query from
/// `rows`, which lists what the journal holds by then and every row written
/// after: a failure never leaves a list stopped for the rest of the app's life.
public func followLiveList<Rows: AsyncSequence>(
  _ rows: () -> Rows,
  clock: any AthinaClock,
  backOff: Duration,
  restarting: (any Error) -> Void,
  deliver: (Rows.Element) -> Void,
  isolation: isolated (any Actor)? = #isolation
) async {
  while !Task.isCancelled {
    do {
      for try await value in rows() {
        deliver(value)
      }
      return
    } catch {
      if Task.isCancelled { return }
      restarting(error)
      do {
        try await clock.sleep(for: backOff)
      } catch {
        return
      }
    }
  }
}

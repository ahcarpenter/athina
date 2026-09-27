#if E2EAPI
  import Testing

  /// The API tier of the end-to-end harness (README "End-to-end harness").
  ///
  /// Each test is one scenario, named as `scripts/e2e/athina-e2e run` and `list` name it, which
  /// launches a hermetic replay and drives Athina through its control API. The first paragraph
  /// of each one's doc comment is what `list` says it proves.
  ///
  /// The scenarios run side by side, as many at once as the harness's `--jobs` allows, since a
  /// hermetic run shares nothing with another.
  @Suite struct Scenarios {}
#endif

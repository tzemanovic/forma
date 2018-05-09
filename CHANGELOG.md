## Forma 1.0.0

* Changed `runForm` function to return `BranchState`
  (the original response can be constructed with `toJSON . toResponse`).
* Added `subParser` and `value` combinators. Changed signature of
  `mkFieldError` to accept `NonEmpty (SelectedName names)` as first
  argument.
* Added `toResponse` that converts `BranchState` to `Response`.
* Exported `showFieldPath` and `FieldError`'s value constructor.

## Forma 0.2.0

* Added `withCheck`.

## Forma 0.1.0

* Initial release.

## Forma 1.0.0

* Renamed the validation callback result:
  * `FormResult` => `ValidationResult`
  * `FormResultError` => `ValidationError`
  * `FormResultSuccess` => `ValidationSuccess`
* Renamed the overall result:
  * `BranchState` => `FormResult`
  * `ParsingFailed` => `FormParsingError`
  * `ValidationFailed` => `FormValidationError`
  * `Succeeded` => `FormSuccess`
* Changed signature of `mkFieldError` to accept `NonEmpty (SelectedName names)` 
  as first argument.
* Changed `runForm` function to return `FormResult` 
  (use `toJSON . toResponse` to get the original JSON value from version 0.2.0).
* Added `toResponse` that converts `FormResult` to `Response`, which can be 
  serialized to JSON.
* Added `subParser` and `value` combinators.
* Exported `showFieldPath` and `FieldError`'s value constructor.

## Forma 0.2.0

* Added `withCheck`.

## Forma 0.1.0

* Initial release.

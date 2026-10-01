# Lakeraven::Ehr
Short description and motivation.

## Usage
How to use my plugin.

## Installation
Add this line to your application's Gemfile:

```ruby
gem "lakeraven-ehr"
```

And then execute:
```bash
$ bundle
```

Or install it yourself as:
```bash
$ gem install lakeraven-ehr
```

### Styles

Engine pages are styled with Tailwind CSS v4 and link the host's Tailwind build (`tailwind.css`).
The engine ships no build of its own.
The host needs `tailwindcss-rails` (4.x) and includes the engine in its build:

```bash
$ bin/rails tailwindcss:engines
```

Then add this line to the host's `app/assets/tailwind/application.css`:

```css
@import "../builds/tailwind/lakeraven_ehr";
```

The engine's styles cannot restyle the host's own pages.
They define no theme, and every element default is scoped to `.lr-ehr`, the class the engine layout puts on `<body>`.

## Contributing
Contribution directions go here.

## License
The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

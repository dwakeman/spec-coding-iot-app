# Documentation

This directory contains the source files for the Sensor Health Dashboard documentation site, built with [Material for MkDocs](https://squidfunk.github.io/mkdocs-material/).

## Structure

```
docs/
├── index.md                    # Homepage
├── getting-started/            # Getting started guides
│   ├── overview.md
│   ├── quick-start.md
│   ├── installation.md         # TODO
│   └── configuration.md        # TODO
├── spec-coding/                # Spec-coding methodology
│   ├── introduction.md
│   ├── requirements.md         # → ../requirements.md
│   ├── design.md               # → ../design.md
│   ├── sprint-planning.md      # → ../sprint-board.md
│   └── verification.md         # TODO
├── architecture/               # System architecture
│   ├── overview.md
│   ├── data-model.md           # → ../../SCHEMAS.md
│   ├── api-design.md           # TODO
│   ├── data-access-patterns.md # TODO
│   └── federated-query-analysis.md # → ../federated-query-analysis.md
├── user-guide/                 # User documentation
│   ├── dashboard.md            # TODO
│   ├── device-details.md       # TODO
│   ├── anomaly-detection.md    # TODO
│   └── filtering.md            # TODO
├── api/                        # API reference
│   ├── overview.md             # TODO
│   ├── endpoints.md            # TODO
│   ├── data-models.md          # TODO
│   ├── error-handling.md       # TODO
│   └── openapi.yaml            # → ../openapi.yaml
├── development/                # Development guides
│   ├── setup.md                # TODO
│   ├── testing.md              # TODO
│   ├── observability.md        # → ../observability-and-resilience.md
│   └── contributing.md         # TODO
├── operations/                 # Operations guides
│   ├── demo-readiness.md       # → ../demo-readiness.md
│   ├── troubleshooting.md      # → ../getting-unstuck.md
│   ├── windows-setup.md        # → ../setup-windows-wsl2.md
│   └── performance.md          # TODO
└── reference/                  # Reference documentation
    ├── requirements-traceability.md # → ../requirements-traceability-matrix.md
    ├── project-summary.md      # → ../PROJECT-SUMMARY.md
    ├── installation-summary.md # → ../INSTALLATION-SUMMARY.md
    └── final-report.md         # → ../FINAL-DEMO-READINESS-REPORT.md
```

## Building Locally

### Prerequisites

```bash
pip install -r requirements.txt
```

### Build the Site

```bash
# Build static site
mkdocs build

# Serve locally with live reload
mkdocs serve
```

The site will be available at http://127.0.0.1:8000

### Strict Mode

Build with strict mode to catch warnings:

```bash
mkdocs build --strict
```

## Deployment

The documentation is automatically deployed to GitHub Pages via GitHub Actions on every push to `main`.

### Manual Deployment

```bash
mkdocs gh-deploy
```

This will:
1. Build the site
2. Push to the `gh-pages` branch
3. GitHub Pages will serve it at https://dwakeman.github.io/spec-coding-iot-app/

## Writing Documentation

### Markdown Extensions

Material for MkDocs supports many extensions:

#### Admonitions

```markdown
!!! note "Optional Title"
    This is a note.

!!! warning
    This is a warning.

!!! tip
    This is a tip.
```

#### Code Blocks

````markdown
```python title="example.py"
def hello():
    print("Hello, World!")
```
````

#### Tabs

```markdown
=== "Tab 1"
    Content for tab 1

=== "Tab 2"
    Content for tab 2
```

#### Mermaid Diagrams

````markdown
```mermaid
graph LR
    A[Start] --> B[End]
```
````

### Navigation

Edit `mkdocs.yml` to update the navigation structure:

```yaml
nav:
  - Home: index.md
  - Getting Started:
    - Overview: getting-started/overview.md
```

## Configuration

The site is configured in `mkdocs.yml` at the project root. Key sections:

- `theme`: Material theme configuration
- `markdown_extensions`: Enabled Markdown features
- `plugins`: Additional functionality
- `nav`: Navigation structure

## Contributing

When adding new documentation:

1. Create the `.md` file in the appropriate directory
2. Add it to the `nav` section in `mkdocs.yml`
3. Use relative links to other docs: `[Link](../other-doc.md)`
4. Test locally with `mkdocs serve`
5. Commit and push - GitHub Actions will deploy automatically

## Resources

- [Material for MkDocs Documentation](https://squidfunk.github.io/mkdocs-material/)
- [MkDocs Documentation](https://www.mkdocs.org/)
- [Markdown Guide](https://www.markdownguide.org/)
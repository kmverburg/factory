# Previews and screenshots

Koen can see what a PR does from the Linear ticket, without opening GitHub: the reviewer's comment has a link to the preview and up to 3 screenshots.

## How it works
1. **Preview.** If an app's `CLAUDE.md` describes a per-PR preview (where to find its URL for a PR, and what it contains), the reviewer opens that URL in the headless browser and clicks through the change there. Apps describe it in their own `CLAUDE.md`; the factory has no per-app config for it.
2. **No preview.** If the app has none, or it failed to load, the reviewer runs the app locally as before and the comments say the preview wasn't available.
3. **Verdict.** The reviewer writes `preview_url` (https, or empty) and `screenshots` (`[{"path": ".factory-review/x.png", "caption": "…"}]`, at most 3) into `.factory-review/verdict.json`.
4. **Publish.** `agents/review/publish.sh` keeps only PNG files directly under `.factory-review/` (no symlinks, max 5 MB), uploads them to Linear with `linear_upload_image` (`agents/lib/linear.sh`: the `fileUpload` mutation, then a PUT to the signed URL), and puts the link and the images (as markdown, using Linear's asset URL) in the Linear comment and in the PR's review comment. A non-https preview URL is dropped.

## Good to know
- Screenshots are only uploaded for PRs with a Linear ticket and a `LINEAR_API_KEY`. Without them the PR comment still shows the preview link, but no images.
- A failed upload never fails the review: the image is skipped with a warning.
- **No secrets or real user data.** The reviewer must only use a preview with example data, or a local run with seed data, and only list screenshots it looked at. This is a rule in the reviewer prompt, not something code can check.
- Setting up previews in the apps is separate work (Backpack: KV-42, Feast: KV-44).

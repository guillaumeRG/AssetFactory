import json
import os
import re
import sys
import traceback

import unreal


def fail(message, job_path=None, job=None):
    if job_path and job is not None:
        job["status"] = "failed"
        job["error"] = message
        try:
            with open(job_path, "w", encoding="utf-8") as handle:
                json.dump(job, handle, indent=2)
        except Exception:
            pass
    unreal.log_error(f"[AssetFactory] {message}")
    raise RuntimeError(message)


def safe_set(obj, property_name, value):
    try:
        obj.set_editor_property(property_name, value)
        return True
    except Exception as exc:
        unreal.log_warning(
            f"[AssetFactory] Could not set '{property_name}' to '{value}': {exc}"
        )
        return False


def sanitize_asset_name(value):
    cleaned = re.sub(r"[^A-Za-z0-9_]", "_", value.strip())
    cleaned = re.sub(r"_+", "_", cleaned).strip("_")
    if not cleaned:
        raise ValueError("Asset name becomes empty after sanitization.")
    if cleaned[0].isdigit():
        cleaned = "A_" + cleaned
    return cleaned


def sanitize_category(value):
    if not value:
        return ""
    parts = []
    for raw_part in str(value).replace("\\", "/").split("/"):
        part = re.sub(r"[^A-Za-z0-9_]", "_", raw_part.strip())
        part = re.sub(r"_+", "_", part).strip("_")
        if part:
            parts.append(part)
    return "/".join(parts)


def main():
    job_path = os.environ.get("ASSET_FACTORY_IMPORT_JOB", "").strip()
    if not job_path:
        raise RuntimeError(
            "ASSET_FACTORY_IMPORT_JOB environment variable is missing."
        )

    job_path = os.path.abspath(job_path)

    if not os.path.isfile(job_path):
        raise RuntimeError(f"Import job does not exist: {job_path}")

    with open(job_path, "r", encoding="utf-8-sig") as handle:
        job = json.load(handle)

    try:
        fbx_path = os.path.abspath(job["fbxPath"])
        asset_id = sanitize_asset_name(job["assetId"])
        category = sanitize_category(job.get("category", ""))
        content_root = str(job["contentRoot"]).rstrip("/")

        if not content_root.startswith("/Game"):
            fail(
                f"contentRoot must start with /Game, got: {content_root}",
                job_path,
                job,
            )

        if not os.path.isfile(fbx_path):
            fail(f"FBX file not found: {fbx_path}", job_path, job)

        destination_path = content_root
        if category:
            destination_path += "/" + category

        settings = job.get("importSettings", {})

        task = unreal.AssetImportTask()
        task.set_editor_property("filename", fbx_path)
        task.set_editor_property("destination_path", destination_path)
        task.set_editor_property("destination_name", asset_id)
        task.set_editor_property("automated", True)
        task.set_editor_property(
            "replace_existing",
            bool(settings.get("replaceExisting", True)),
        )
        task.set_editor_property("save", True)

        options = unreal.FbxImportUI()
        safe_set(options, "import_mesh", True)
        safe_set(options, "import_as_skeletal", False)
        safe_set(options, "mesh_type", unreal.FBXImportType.FBXIT_STATIC_MESH)
        safe_set(
            options,
            "import_materials",
            bool(settings.get("importMaterials", False)),
        )
        safe_set(
            options,
            "import_textures",
            bool(settings.get("importTextures", False)),
        )

        static_data = options.get_editor_property("static_mesh_import_data")
        if static_data:
            safe_set(
                static_data,
                "combine_meshes",
                bool(settings.get("combineMeshes", True)),
            )
            safe_set(
                static_data,
                "generate_lightmap_u_vs",
                bool(settings.get("generateLightmapUVs", True)),
            )
            safe_set(
                static_data,
                "auto_generate_collision",
                bool(settings.get("autoGenerateCollision", True)),
            )

        task.set_editor_property("options", options)

        unreal.log(
            f"[AssetFactory] Importing '{fbx_path}' -> "
            f"'{destination_path}/{asset_id}'"
        )

        asset_tools = unreal.AssetToolsHelpers.get_asset_tools()
        asset_tools.import_asset_tasks([task])

        imported_paths = list(task.get_editor_property("imported_object_paths") or [])

        if not imported_paths:
            fail(
                "Unreal import completed without returning any imported object path.",
                job_path,
                job,
            )

        saved_paths = []
        for object_path in imported_paths:
            package_path = str(object_path).split(".", 1)[0]
            try:
                if unreal.EditorAssetLibrary.save_asset(
                    package_path,
                    only_if_is_dirty=False,
                ):
                    saved_paths.append(str(object_path))
                else:
                    saved_paths.append(str(object_path))
            except Exception as exc:
                unreal.log_warning(
                    f"[AssetFactory] Could not explicitly save '{package_path}': {exc}"
                )
                saved_paths.append(str(object_path))

        job["status"] = "completed"
        job["error"] = None
        job["destinationPath"] = destination_path
        job["assetName"] = asset_id
        job["importedObjectPaths"] = saved_paths

        with open(job_path, "w", encoding="utf-8") as handle:
            json.dump(job, handle, indent=2)

        for object_path in saved_paths:
            unreal.log(f"[AssetFactory] Imported: {object_path}")

        unreal.log("[AssetFactory] Import completed.")

    except Exception as exc:
        message = f"{exc}"
        unreal.log_error(traceback.format_exc())
        fail(message, job_path, job)


if __name__ == "__main__":
    main()

import json
import os
import re
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


def sanitize_asset_version(value):
    if value is None or str(value).strip() == "":
        return ""
    version = str(value).strip().lower()
    if not re.fullmatch(r"v[0-9]{3,}", version):
        raise ValueError(
            f"assetVersion must use the form v001, v002, ...; got: {value}"
        )
    return version


def directory_is_occupied(path):
    library = unreal.EditorAssetLibrary
    if hasattr(library, "does_directory_exist") and library.does_directory_exist(path):
        return True
    if hasattr(library, "list_assets"):
        return bool(library.list_assets(path, recursive=True, include_folder=False))
    return False


def resolve_asset_version(base_path, requested_version="", overwrite_existing=False):
    """Choisit une version Unreal sans écraser une génération précédente par défaut."""
    requested = sanitize_asset_version(requested_version)
    if requested:
        requested_path = f"{base_path}/{requested}"
        if overwrite_existing or not directory_is_occupied(requested_path):
            return requested
        start = int(requested[1:]) + 1
    else:
        start = 1

    for number in range(start, 1000000):
        candidate = f"v{number:03d}"
        if not directory_is_occupied(f"{base_path}/{candidate}"):
            return candidate
    raise RuntimeError(f"No free asset version could be allocated under: {base_path}")


def make_fbx_options(settings):
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
    return options


def require_set(obj, property_name, value):
    """N'ignore pas silencieusement une option d'import GLB demandée."""
    try:
        obj.set_editor_property(property_name, value)
    except Exception as exc:
        raise RuntimeError(
            f"Cannot configure Interchange property '{property_name}': {exc}"
        ) from exc


def make_glb_options(settings, asset_id):
    """Pipelines Interchange transitoires : aucun pipeline .uasset ni modification du moteur."""
    required_classes = (
        "InterchangeGenericAssetsPipeline",
        "InterchangeGLTFPipeline",
        "InterchangePipelineStackOverride",
    )
    for name in required_classes:
        if not hasattr(unreal, name):
            raise RuntimeError(
                f"Unreal {name} is unavailable. Enable the Interchange plugins "
                "in the selected project, then retry this import."
            )

    pipeline = unreal.InterchangeGenericAssetsPipeline()
    # AssetImportTask.destination_name est ignoré pour les imports Interchange.
    require_set(pipeline, "asset_name", asset_id)
    require_set(pipeline, "use_source_name_for_asset", True)
    require_set(pipeline, "asset_type_sub_folders", False)
    require_set(pipeline, "scene_name_sub_folder", False)

    mesh = pipeline.get_editor_property("mesh_pipeline")
    require_set(mesh, "import_static_meshes", True)
    require_set(mesh, "import_skeletal_meshes", False)
    combine = bool(settings.get("combineMeshes", True))
    # UE 5.8 a remplacé l'ancien booléen combine_static_meshes par une énumération.
    behavior = getattr(unreal, "InterchangeCombineStaticMeshesBehavior", None)
    if behavior is not None:
        value = behavior.ALL if combine else behavior.DO_NOT_COMBINE
        require_set(mesh, "combine_static_meshes_behavior", value)
    else:
        require_set(mesh, "combine_static_meshes", combine)
    require_set(
        mesh, "generate_lightmap_u_vs", bool(settings.get("generateLightmapUVs", True))
    )
    require_set(mesh, "collision", bool(settings.get("autoGenerateCollision", True)))

    animation = pipeline.get_editor_property("animation_pipeline")
    require_set(animation, "import_animations", False)
    material = pipeline.get_editor_property("material_pipeline")
    require_set(material, "import_materials", bool(settings.get("importMaterials", True)))
    # Recherche uniquement dans la destination choisie, pas dans d'autres assets nommés material_0.
    if hasattr(unreal, "InterchangeMaterialSearchLocation"):
        require_set(
            material, "search_location", unreal.InterchangeMaterialSearchLocation.LOCAL
        )
    texture = material.get_editor_property("texture_pipeline")
    require_set(texture, "import_textures", bool(settings.get("importTextures", True)))

    gltf_pipeline = unreal.InterchangeGLTFPipeline()
    stack = unreal.InterchangePipelineStackOverride()
    stack.add_pipeline(pipeline)
    stack.add_pipeline(gltf_pipeline)
    # Les entrées SoftObjectPath ne possèdent pas les pipelines transitoires ; on les conserve jusqu'à
    # la fin de l'import synchrone et jusqu'à ce que chaque asset retourné soit enregistré.
    return stack, (pipeline, gltf_pipeline)


def resolve_source(job):
    raw_path = job.get("sourcePath") or job.get("fbxPath")
    if not isinstance(raw_path, str) or not raw_path.strip():
        raise ValueError("Import job is missing sourcePath (or legacy fbxPath).")
    source_path = os.path.abspath(raw_path)
    extension = os.path.splitext(source_path)[1].lower()
    if extension not in (".fbx", ".glb"):
        raise ValueError(f"Unsupported model format '{extension}'; expected .fbx or .glb.")
    if not os.path.isfile(source_path):
        raise FileNotFoundError(f"Source model not found: {source_path}")
    if os.path.getsize(source_path) == 0:
        raise ValueError(f"Source model is empty: {source_path}")
    return source_path, extension


def validate_content_root(value):
    root = str(value).rstrip("/")
    if not re.fullmatch(r"/Game(?:/[A-Za-z0-9_]+)*", root):
        raise ValueError(f"contentRoot must be /Game or valid folders under /Game, got: {root}")
    return root


def collect_imported_objects(task):
    # get_objects attend le résultat Interchange asynchrone si nécessaire.
    objects = list(task.get_objects() or [])
    objects_by_path = {
        str(obj.get_path_name()): obj for obj in objects if obj is not None
    }
    for path in task.get_editor_property("imported_object_paths") or []:
        path = str(path)
        if path not in objects_by_path:
            obj = unreal.EditorAssetLibrary.load_asset(path)
            if obj is None:
                raise RuntimeError(f"Imported object cannot be loaded: {path}")
            objects_by_path[path] = obj
    if not objects_by_path:
        raise RuntimeError("Unreal returned no imported object.")
    mesh_paths = [
        path for path, obj in objects_by_path.items() if isinstance(obj, unreal.StaticMesh)
    ]
    if not mesh_paths:
        raise RuntimeError("Unreal returned assets but no StaticMesh; import is not validated.")
    return objects_by_path, mesh_paths


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
        source_path, extension = resolve_source(job)
        default_name = os.path.splitext(os.path.basename(source_path))[0]
        asset_id = sanitize_asset_name(job.get("assetId") or default_name)
        category = sanitize_category(job.get("category", ""))
        content_root = validate_content_root(job["contentRoot"])
        job["sourcePath"] = source_path
        job["sourceFormat"] = extension.lstrip(".")

        asset_base_path = content_root
        if category:
            asset_base_path += "/" + category
        asset_base_path += "/" + asset_id

        settings = job.get("importSettings", {})
        if not isinstance(settings, dict):
            raise ValueError("importSettings must be an object.")
        for name, value in settings.items():
            if not isinstance(value, bool):
                raise ValueError(f"importSettings.{name} must be a JSON boolean.")

        overwrite_existing_version = job.get("overwriteExistingVersion", False)
        if not isinstance(overwrite_existing_version, bool):
            raise ValueError("overwriteExistingVersion must be a JSON boolean.")
        requested_version = job.get("requestedAssetVersion") or job.get("assetVersion") or ""
        asset_version = resolve_asset_version(
            asset_base_path, requested_version, overwrite_existing_version
        )
        destination_path = f"{asset_base_path}/{asset_version}"
        job["requestedAssetVersion"] = sanitize_asset_version(requested_version) or None
        job["assetVersion"] = asset_version
        job["overwriteExistingVersion"] = overwrite_existing_version

        task = unreal.AssetImportTask()
        task.set_editor_property("filename", source_path)
        task.set_editor_property("destination_path", destination_path)
        task.set_editor_property("destination_name", asset_id)
        task.set_editor_property("automated", True)
        task.set_editor_property("async_", False)
        task.set_editor_property(
            "replace_existing",
            bool(settings.get("replaceExisting", True)),
        )
        task.set_editor_property("save", True)

        pipeline_keepalive = ()
        if extension == ".fbx":
            options = make_fbx_options(settings)
            job["importer"] = "fbx"
        else:
            options, pipeline_keepalive = make_glb_options(settings, asset_id)
            job["importer"] = "interchange-glb"

        task.set_editor_property("options", options)

        unreal.log(
            f"[AssetFactory] Importing '{source_path}' -> "
            f"'{destination_path}/{asset_id}'"
        )

        asset_tools = unreal.AssetToolsHelpers.get_asset_tools()
        asset_tools.import_asset_tasks([task])

        objects_by_path, mesh_paths = collect_imported_objects(task)
        imported_paths = list(objects_by_path)
        job["importedObjectPaths"] = imported_paths
        job["meshObjectPaths"] = mesh_paths
        job["destinationPath"] = destination_path
        job["assetName"] = asset_id
        saved_paths = []
        for object_path in imported_paths:
            package_path = str(object_path).split(".", 1)[0]
            if not unreal.EditorAssetLibrary.save_asset(package_path, only_if_is_dirty=False):
                raise RuntimeError(f"Unreal could not save imported asset: {package_path}")
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

#include "AI/WorldDirectorCodexProtocol.h"
#include "AI/WorldDirectorCommandProposalParser.h"
#include "WorldDirectorCapabilities.h"
#include "WorldDirectorEnvironmentAssetCatalog.h"

#include "Dom/JsonObject.h"
#include "Serialization/JsonReader.h"
#include "Serialization/JsonSerializer.h"
#include "Serialization/JsonWriter.h"
#include "Policies/CondensedJsonPrintPolicy.h"
#include "Misc/Paths.h"

namespace
{
	FString SerializeJson(const TSharedRef<FJsonObject>& Object);
	FString CodexWorkingDirectory()
	{
		return FPaths::Combine(FPlatformProcess::UserTempDir(), TEXT("NullOnWorldDirector"));
	}

	TSharedRef<FJsonObject> StringSchema()
	{
		const TSharedRef<FJsonObject> Schema = MakeShared<FJsonObject>();
		Schema->SetStringField(TEXT("type"), TEXT("string"));
		return Schema;
	}

	TSharedRef<FJsonObject> NumberSchema()
	{
		const TSharedRef<FJsonObject> Schema = MakeShared<FJsonObject>();
		Schema->SetStringField(TEXT("type"), TEXT("number"));
		return Schema;
	}

	TSharedRef<FJsonObject> IntegerSchema()
	{
		const TSharedRef<FJsonObject> Schema = MakeShared<FJsonObject>();
		Schema->SetStringField(TEXT("type"), TEXT("integer"));
		return Schema;
	}

	TSharedRef<FJsonObject> BooleanSchema()
	{
		const TSharedRef<FJsonObject> Schema = MakeShared<FJsonObject>();
		Schema->SetStringField(TEXT("type"), TEXT("boolean"));
		return Schema;
	}

	TSharedRef<FJsonObject> EnumSchema(std::initializer_list<const TCHAR*> Values)
	{
		const TSharedRef<FJsonObject> Schema = StringSchema();
		TArray<TSharedPtr<FJsonValue>> JsonValues;
		for (const TCHAR* Value : Values)
		{
			JsonValues.Add(MakeShared<FJsonValueString>(Value));
		}
		Schema->SetArrayField(TEXT("enum"), JsonValues);
		return Schema;
	}

	TSharedRef<FJsonObject> NullableStringSchema()
	{
		const TSharedRef<FJsonObject> Schema = MakeShared<FJsonObject>();
		Schema->SetArrayField(
			TEXT("type"),
			{MakeShared<FJsonValueString>(TEXT("string")), MakeShared<FJsonValueString>(TEXT("null"))});
		return Schema;
	}

	TSharedRef<FJsonObject> ObjectSchema(
		const TSharedRef<FJsonObject>& Properties,
		std::initializer_list<const TCHAR*> Required)
	{
		const TSharedRef<FJsonObject> Schema = MakeShared<FJsonObject>();
		Schema->SetStringField(TEXT("type"), TEXT("object"));
		Schema->SetObjectField(TEXT("properties"), Properties);
		TArray<TSharedPtr<FJsonValue>> RequiredValues;
		for (const TCHAR* Value : Required)
		{
			RequiredValues.Add(MakeShared<FJsonValueString>(Value));
		}
		Schema->SetArrayField(TEXT("required"), RequiredValues);
		Schema->SetBoolField(TEXT("additionalProperties"), false);
		return Schema;
	}

	TSharedRef<FJsonObject> BuildBodyProperties()
	{
		const TSharedRef<FJsonObject> Properties = MakeShared<FJsonObject>();
		Properties->SetObjectField(TEXT("persistentId"), StringSchema());
		Properties->SetObjectField(TEXT("displayName"), StringSchema());
		Properties->SetObjectField(TEXT("semanticType"), EnumSchema({TEXT("Planet"), TEXT("Moon"), TEXT("Asteroid")}));
		Properties->SetObjectField(TEXT("radiusKm"), NumberSchema());
		Properties->SetObjectField(TEXT("hasAtmosphere"), BooleanSchema());
		Properties->SetObjectField(TEXT("surfaceStrategy"), EnumSchema({TEXT("Regional"), TEXT("SphericalContinuous")}));
		Properties->SetObjectField(TEXT("spaceTransitionStrategy"), EnumSchema({TEXT("AtmosphericLoading"), TEXT("Continuous")}));
		Properties->SetObjectField(TEXT("gravityStrategy"), EnumSchema({TEXT("Standard"), TEXT("Radial")}));
		Properties->SetObjectField(TEXT("surfaceGravity"), NumberSchema());
		Properties->SetObjectField(TEXT("parentBodyId"), NullableStringSchema());
		return Properties;
	}

	TSharedRef<FJsonObject> BuildCommandSchema(
		const TCHAR* Type,
		const TSharedRef<FJsonObject>& PayloadSchema)
	{
		const TSharedRef<FJsonObject> TypeSchema = EnumSchema({Type});
		const TSharedRef<FJsonObject> Properties = MakeShared<FJsonObject>();
		Properties->SetObjectField(TEXT("type"), TypeSchema);
		Properties->SetObjectField(TEXT("payload"), PayloadSchema);
		return ObjectSchema(Properties, {TEXT("type"), TEXT("payload")});
	}

	TSharedRef<FJsonObject> BuildPatchFieldSchema(const TSharedRef<FJsonObject>& ValueSchema)
	{
		const TSharedRef<FJsonObject> Properties = MakeShared<FJsonObject>();
		Properties->SetObjectField(TEXT("isSet"), BooleanSchema());
		Properties->SetObjectField(TEXT("value"), ValueSchema);
		return ObjectSchema(Properties, {TEXT("isSet"), TEXT("value")});
	}

	TSharedRef<FJsonObject> BuildTerrainFeaturePositionSchema()
	{
		const TSharedRef<FJsonObject> Properties = MakeShared<FJsonObject>();
		Properties->SetObjectField(TEXT("latitudeDeg"), NumberSchema());
		Properties->SetObjectField(TEXT("longitudeDeg"), NumberSchema());
		Properties->SetObjectField(TEXT("elevationKm"), NumberSchema());
		return ObjectSchema(Properties, {TEXT("latitudeDeg"), TEXT("longitudeDeg"), TEXT("elevationKm")});
	}

	TSharedRef<FJsonObject> BuildEnvironmentTerrainPathPointSchema()
	{
		const TSharedRef<FJsonObject> Properties = MakeShared<FJsonObject>();
		Properties->SetObjectField(TEXT("xMeters"), NumberSchema());
		Properties->SetObjectField(TEXT("yMeters"), NumberSchema());
		return ObjectSchema(Properties, {TEXT("xMeters"), TEXT("yMeters")});
	}

	TSharedRef<FJsonObject> BuildEnvironmentTerrainPathSchema()
	{
		const TSharedRef<FJsonObject> Schema = MakeShared<FJsonObject>();
		Schema->SetStringField(TEXT("type"), TEXT("array"));
		Schema->SetObjectField(TEXT("items"), BuildEnvironmentTerrainPathPointSchema());
		return Schema;
	}

	TSharedRef<FJsonObject> BuildTerrainFeatureSchema()
	{
		const TSharedRef<FJsonObject> Properties = MakeShared<FJsonObject>();
		Properties->SetObjectField(TEXT("persistentId"), StringSchema());
		Properties->SetObjectField(TEXT("displayName"), StringSchema());
		Properties->SetObjectField(TEXT("bodyId"), StringSchema());
		Properties->SetObjectField(TEXT("type"), EnumSchema({TEXT("Crater"), TEXT("Canyon"), TEXT("MountainRange"), TEXT("Plain"), TEXT("Valley"), TEXT("Plateau"), TEXT("Hill")}));
		Properties->SetObjectField(TEXT("position"), BuildTerrainFeaturePositionSchema());
		Properties->SetObjectField(TEXT("sizeKm"), NumberSchema());
		Properties->SetObjectField(TEXT("intensity"), NumberSchema());
		Properties->SetObjectField(TEXT("environmentCenterXMeters"), NumberSchema());
		Properties->SetObjectField(TEXT("environmentCenterYMeters"), NumberSchema());
		Properties->SetObjectField(TEXT("radiusMeters"), NumberSchema());
		Properties->SetObjectField(TEXT("depthMeters"), NumberSchema());
		Properties->SetObjectField(TEXT("heightMeters"), NumberSchema());
		Properties->SetObjectField(TEXT("falloff"), NumberSchema());
		Properties->SetObjectField(TEXT("widthMeters"), NumberSchema());
		Properties->SetObjectField(TEXT("compositionOrder"), IntegerSchema());
		Properties->SetObjectField(TEXT("environmentPath"), BuildEnvironmentTerrainPathSchema());
		return ObjectSchema(
			Properties,
			{TEXT("persistentId"), TEXT("displayName"), TEXT("bodyId"), TEXT("type"),
			 TEXT("position"), TEXT("sizeKm"), TEXT("intensity"),
			 TEXT("environmentCenterXMeters"), TEXT("environmentCenterYMeters"),
			 TEXT("radiusMeters"), TEXT("depthMeters"), TEXT("heightMeters"), TEXT("falloff"),
			 TEXT("widthMeters"), TEXT("compositionOrder"), TEXT("environmentPath")});
	}

	TSharedRef<FJsonObject> BuildRegionSchema()
	{
		const TSharedRef<FJsonObject> Properties = MakeShared<FJsonObject>();
		Properties->SetObjectField(TEXT("persistentId"), StringSchema());
		Properties->SetObjectField(TEXT("displayName"), StringSchema());
		Properties->SetObjectField(TEXT("bodyId"), StringSchema());
		Properties->SetObjectField(TEXT("environmentId"), StringSchema());
		Properties->SetObjectField(TEXT("position"), BuildTerrainFeaturePositionSchema());
		Properties->SetObjectField(TEXT("radiusKm"), NumberSchema());
		Properties->SetObjectField(TEXT("environmentCenterXMeters"), NumberSchema());
		Properties->SetObjectField(TEXT("environmentCenterYMeters"), NumberSchema());
		Properties->SetObjectField(TEXT("radiusMeters"), NumberSchema());
		Properties->SetObjectField(TEXT("biomeId"), NullableStringSchema());
		return ObjectSchema(Properties, {TEXT("persistentId"), TEXT("displayName"), TEXT("bodyId"), TEXT("environmentId"),
			TEXT("position"), TEXT("radiusKm"), TEXT("environmentCenterXMeters"), TEXT("environmentCenterYMeters"), TEXT("radiusMeters"), TEXT("biomeId")});
	}

	TSharedRef<FJsonObject> BuildBiomeSchema()
	{
		const TSharedRef<FJsonObject> Properties = MakeShared<FJsonObject>();
		Properties->SetObjectField(TEXT("persistentId"), StringSchema());
		Properties->SetObjectField(TEXT("displayName"), StringSchema());
		Properties->SetObjectField(TEXT("temperature"), NumberSchema());
		Properties->SetObjectField(TEXT("humidity"), NumberSchema());
		Properties->SetObjectField(TEXT("vegetationLevel"), NumberSchema());
		Properties->SetObjectField(TEXT("rockiness"), NumberSchema());
		return ObjectSchema(Properties, {TEXT("persistentId"), TEXT("displayName"), TEXT("temperature"), TEXT("humidity"), TEXT("vegetationLevel"), TEXT("rockiness")});
	}


	TSharedRef<FJsonObject> BuildDressingCategoryArraySchema()
	{
		const TSharedRef<FJsonObject> Schema = MakeShared<FJsonObject>();
		Schema->SetStringField(TEXT("type"), TEXT("array"));
		Schema->SetObjectField(TEXT("items"), EnumSchema({TEXT("Trees"), TEXT("Bushes"), TEXT("Grass"), TEXT("Stones"), TEXT("Rocks")}));
		return Schema;
	}

	TSharedRef<FJsonObject> BuildStringArraySchema()
	{
		const TSharedRef<FJsonObject> Schema = MakeShared<FJsonObject>();
		Schema->SetStringField(TEXT("type"), TEXT("array"));
		Schema->SetObjectField(TEXT("items"), StringSchema());
		return Schema;
	}

	TSharedRef<FJsonObject> BuildIntegerArraySchema()
	{
		const TSharedRef<FJsonObject> Schema = MakeShared<FJsonObject>();
		Schema->SetStringField(TEXT("type"), TEXT("array"));
		Schema->SetObjectField(TEXT("items"), IntegerSchema());
		return Schema;
	}

	TSharedRef<FJsonObject> BuildWorldBuildPlanSchema()
	{
		const TSharedRef<FJsonObject> PhaseProperties = MakeShared<FJsonObject>();
		PhaseProperties->SetObjectField(TEXT("phaseId"), StringSchema());
		PhaseProperties->SetObjectField(TEXT("displayName"), StringSchema());
		PhaseProperties->SetObjectField(TEXT("order"), IntegerSchema());
		PhaseProperties->SetObjectField(TEXT("dependsOn"), BuildStringArraySchema());
		PhaseProperties->SetObjectField(TEXT("checkpointAfter"), BooleanSchema());
		PhaseProperties->SetObjectField(TEXT("commandIndices"), BuildIntegerArraySchema());
		const TSharedRef<FJsonObject> PhaseSchema = ObjectSchema(
			PhaseProperties,
			{TEXT("phaseId"), TEXT("displayName"), TEXT("order"), TEXT("dependsOn"), TEXT("checkpointAfter"), TEXT("commandIndices")});

		const TSharedRef<FJsonObject> PhasesSchema = MakeShared<FJsonObject>();
		PhasesSchema->SetStringField(TEXT("type"), TEXT("array"));
		PhasesSchema->SetObjectField(TEXT("items"), PhaseSchema);

		const TSharedRef<FJsonObject> Properties = MakeShared<FJsonObject>();
		Properties->SetObjectField(TEXT("planId"), StringSchema());
		Properties->SetObjectField(TEXT("goal"), StringSchema());
		Properties->SetObjectField(TEXT("seed"), IntegerSchema());
		Properties->SetObjectField(TEXT("phases"), PhasesSchema);
		return ObjectSchema(Properties, {TEXT("planId"), TEXT("goal"), TEXT("seed"), TEXT("phases")});
	}

	TSharedRef<FJsonObject> BuildDressingCenterSchema()
	{
		const TSharedRef<FJsonObject> Properties = MakeShared<FJsonObject>();
		Properties->SetObjectField(TEXT("xMeters"), NumberSchema());
		Properties->SetObjectField(TEXT("yMeters"), NumberSchema());
		return ObjectSchema(Properties, {TEXT("xMeters"), TEXT("yMeters")});
	}

	TSharedRef<FJsonObject> BuildDressingSlopeRangeSchema()
	{
		const TSharedRef<FJsonObject> Properties = MakeShared<FJsonObject>();
		Properties->SetObjectField(TEXT("minDegrees"), NumberSchema());
		Properties->SetObjectField(TEXT("maxDegrees"), NumberSchema());
		return ObjectSchema(Properties, {TEXT("minDegrees"), TEXT("maxDegrees")});
	}

	TSharedRef<FJsonObject> BuildDressingElevationRangeSchema()
	{
		const TSharedRef<FJsonObject> Properties = MakeShared<FJsonObject>();
		Properties->SetObjectField(TEXT("minMeters"), NumberSchema());
		Properties->SetObjectField(TEXT("maxMeters"), NumberSchema());
		return ObjectSchema(Properties, {TEXT("minMeters"), TEXT("maxMeters")});
	}

	TSharedRef<FJsonObject> BuildEnvironmentDressingSchema()
	{
		const TSharedRef<FJsonObject> Properties = MakeShared<FJsonObject>();
		Properties->SetObjectField(TEXT("persistentId"), StringSchema());
		Properties->SetObjectField(TEXT("displayName"), StringSchema());
		Properties->SetObjectField(TEXT("environmentId"), StringSchema());
		Properties->SetObjectField(TEXT("regionId"), NullableStringSchema());
		Properties->SetObjectField(TEXT("centerXMeters"), NumberSchema());
		Properties->SetObjectField(TEXT("centerYMeters"), NumberSchema());
		Properties->SetObjectField(TEXT("radiusMeters"), NumberSchema());
		Properties->SetObjectField(TEXT("categories"), BuildDressingCategoryArraySchema());
		Properties->SetObjectField(TEXT("assetIds"), BuildStringArraySchema());
		Properties->SetObjectField(TEXT("density"), NumberSchema());
		Properties->SetObjectField(TEXT("seed"), IntegerSchema());
		Properties->SetObjectField(TEXT("minSlopeDegrees"), NumberSchema());
		Properties->SetObjectField(TEXT("maxSlopeDegrees"), NumberSchema());
		Properties->SetObjectField(TEXT("minElevationMeters"), NumberSchema());
		Properties->SetObjectField(TEXT("maxElevationMeters"), NumberSchema());
		return ObjectSchema(Properties, {
			TEXT("persistentId"), TEXT("displayName"), TEXT("environmentId"), TEXT("regionId"),
			TEXT("centerXMeters"), TEXT("centerYMeters"), TEXT("radiusMeters"), TEXT("categories"), TEXT("assetIds"),
			TEXT("density"), TEXT("seed"), TEXT("minSlopeDegrees"), TEXT("maxSlopeDegrees"),
			TEXT("minElevationMeters"), TEXT("maxElevationMeters")});
	}


	TSharedRef<FJsonObject> BuildDressingOverrideSchema()
	{
		const TSharedRef<FJsonObject> P = MakeShared<FJsonObject>();
		P->SetObjectField(TEXT("persistentId"), StringSchema()); P->SetObjectField(TEXT("displayName"), StringSchema());
		P->SetObjectField(TEXT("environmentId"), StringSchema()); P->SetObjectField(TEXT("targetDressingId"), NullableStringSchema());
		P->SetObjectField(TEXT("centerXMeters"), NumberSchema()); P->SetObjectField(TEXT("centerYMeters"), NumberSchema()); P->SetObjectField(TEXT("radiusMeters"), NumberSchema());
		P->SetObjectField(TEXT("categories"), BuildDressingCategoryArraySchema()); P->SetObjectField(TEXT("densityMultiplier"), NumberSchema()); P->SetObjectField(TEXT("exclude"), BooleanSchema()); P->SetObjectField(TEXT("seed"), IntegerSchema());
		return ObjectSchema(P,{TEXT("persistentId"),TEXT("displayName"),TEXT("environmentId"),TEXT("targetDressingId"),TEXT("centerXMeters"),TEXT("centerYMeters"),TEXT("radiusMeters"),TEXT("categories"),TEXT("densityMultiplier"),TEXT("exclude"),TEXT("seed")});
	}

	TSharedRef<FJsonObject> BuildGeometrySchema()
	{
		const TSharedRef<FJsonObject> P = MakeShared<FJsonObject>();
		P->SetObjectField(TEXT("persistentId"),StringSchema()); P->SetObjectField(TEXT("displayName"),StringSchema()); P->SetObjectField(TEXT("environmentId"),StringSchema());
		P->SetObjectField(TEXT("type"),EnumSchema({TEXT("Cliff"),TEXT("Overhang"),TEXT("Arch"),TEXT("RockPillar"),TEXT("RockFormation")}));
		P->SetObjectField(TEXT("centerXMeters"),NumberSchema()); P->SetObjectField(TEXT("centerYMeters"),NumberSchema()); P->SetObjectField(TEXT("elevationOffsetMeters"),NumberSchema());
		P->SetObjectField(TEXT("widthMeters"),NumberSchema()); P->SetObjectField(TEXT("depthMeters"),NumberSchema()); P->SetObjectField(TEXT("heightMeters"),NumberSchema());
		P->SetObjectField(TEXT("yawDegrees"),NumberSchema()); P->SetObjectField(TEXT("seed"),IntegerSchema()); P->SetObjectField(TEXT("assetId"),StringSchema());
		return ObjectSchema(P,{TEXT("persistentId"),TEXT("displayName"),TEXT("environmentId"),TEXT("type"),TEXT("centerXMeters"),TEXT("centerYMeters"),TEXT("elevationOffsetMeters"),TEXT("widthMeters"),TEXT("depthMeters"),TEXT("heightMeters"),TEXT("yawDegrees"),TEXT("seed"),TEXT("assetId")});
	}

	TSharedRef<FJsonObject> BuildMaterialColorSchema()
	{
		const TSharedRef<FJsonObject> Properties = MakeShared<FJsonObject>();
		Properties->SetObjectField(TEXT("red"), NumberSchema());
		Properties->SetObjectField(TEXT("green"), NumberSchema());
		Properties->SetObjectField(TEXT("blue"), NumberSchema());
		return ObjectSchema(Properties, {TEXT("red"), TEXT("green"), TEXT("blue")});
	}

	TSharedRef<FJsonObject> BuildMaterialFamilySchema()
	{
		const TSharedRef<FJsonObject> Properties = MakeShared<FJsonObject>();
		Properties->SetObjectField(TEXT("persistentId"), StringSchema());
		Properties->SetObjectField(TEXT("displayName"), StringSchema());
		Properties->SetObjectField(TEXT("baseColor"), BuildMaterialColorSchema());
		Properties->SetObjectField(TEXT("roughness"), NumberSchema());
		Properties->SetObjectField(TEXT("metallic"), NumberSchema());
		Properties->SetObjectField(TEXT("rockiness"), NumberSchema());
		Properties->SetObjectField(TEXT("dustiness"), NumberSchema());
		return ObjectSchema(
			Properties,
			{TEXT("persistentId"), TEXT("displayName"), TEXT("baseColor"), TEXT("roughness"),
			 TEXT("metallic"), TEXT("rockiness"), TEXT("dustiness")});
	}

	TSharedRef<FJsonObject> BuildEnvironmentTerrainRequestSchema()
	{
		const TSharedRef<FJsonObject> Properties = MakeShared<FJsonObject>();
		Properties->SetObjectField(TEXT("widthMeters"), NumberSchema());
		Properties->SetObjectField(TEXT("heightMeters"), NumberSchema());
		Properties->SetObjectField(TEXT("profile"), EnumSchema({TEXT("flat"), TEXT("rolling"), TEXT("hills")}));
		Properties->SetObjectField(TEXT("baseElevationMeters"), NumberSchema());
		Properties->SetObjectField(TEXT("reliefAmplitudeMeters"), NumberSchema());
		Properties->SetObjectField(TEXT("roughness"), NumberSchema());
		return ObjectSchema(Properties, {
			TEXT("widthMeters"), TEXT("heightMeters"), TEXT("profile"),
			TEXT("baseElevationMeters"), TEXT("reliefAmplitudeMeters"), TEXT("roughness")});
	}

	TSharedRef<FJsonObject> BuildEnvironmentSchema()
	{
		const TSharedRef<FJsonObject> Properties = MakeShared<FJsonObject>();
		Properties->SetObjectField(TEXT("persistentId"), StringSchema());
		Properties->SetObjectField(TEXT("displayName"), StringSchema());
		Properties->SetObjectField(TEXT("seed"), IntegerSchema());
		Properties->SetObjectField(TEXT("terrain"), BuildEnvironmentTerrainRequestSchema());
		return ObjectSchema(Properties, {TEXT("persistentId"), TEXT("displayName"), TEXT("seed"), TEXT("terrain")});
	}

	TSharedRef<FJsonObject> BuildEnvironmentTerrainEditSchema()
	{
		const TSharedRef<FJsonObject> Properties = MakeShared<FJsonObject>();
		Properties->SetObjectField(TEXT("type"), EnumSchema({TEXT("Raise"), TEXT("Lower"), TEXT("Flatten"), TEXT("Smooth")}));
		Properties->SetObjectField(TEXT("centerXMeters"), NumberSchema());
		Properties->SetObjectField(TEXT("centerYMeters"), NumberSchema());
		Properties->SetObjectField(TEXT("radiusMeters"), NumberSchema());
		Properties->SetObjectField(TEXT("amountMeters"), NumberSchema());
		Properties->SetObjectField(TEXT("targetElevationMeters"), NumberSchema());
		Properties->SetObjectField(TEXT("strength"), NumberSchema());
		Properties->SetObjectField(TEXT("falloff"), NumberSchema());
		return ObjectSchema(
			Properties,
			{TEXT("type"), TEXT("centerXMeters"), TEXT("centerYMeters"), TEXT("radiusMeters"),
			 TEXT("amountMeters"), TEXT("targetElevationMeters"), TEXT("strength"), TEXT("falloff")});
	}

	TSharedRef<FJsonObject> BuildOutputSchema()
	{
		const TSharedRef<FJsonObject> CreateSystemProperties = MakeShared<FJsonObject>();
		CreateSystemProperties->SetObjectField(TEXT("systemId"), StringSchema());
		CreateSystemProperties->SetObjectField(TEXT("displayName"), StringSchema());
		const TSharedRef<FJsonObject> CreateSystemPayload = ObjectSchema(
			CreateSystemProperties,
			{TEXT("systemId"), TEXT("displayName")});

		const TSharedRef<FJsonObject> BodySchema = ObjectSchema(
			BuildBodyProperties(),
			{TEXT("persistentId"), TEXT("displayName"), TEXT("semanticType"), TEXT("radiusKm"),
			 TEXT("hasAtmosphere"), TEXT("surfaceStrategy"), TEXT("spaceTransitionStrategy"),
			 TEXT("gravityStrategy"), TEXT("surfaceGravity"), TEXT("parentBodyId")});
		const TSharedRef<FJsonObject> CreateBodyProperties = MakeShared<FJsonObject>();
		CreateBodyProperties->SetObjectField(TEXT("targetSystemId"), StringSchema());
		CreateBodyProperties->SetObjectField(TEXT("body"), BodySchema);
		const TSharedRef<FJsonObject> CreateBodyPayload = ObjectSchema(
			CreateBodyProperties,
			{TEXT("targetSystemId"), TEXT("body")});

		const TSharedRef<FJsonObject> ChangesProperties = MakeShared<FJsonObject>();
		ChangesProperties->SetObjectField(TEXT("displayName"), BuildPatchFieldSchema(StringSchema()));
		ChangesProperties->SetObjectField(TEXT("semanticType"), BuildPatchFieldSchema(
			EnumSchema({TEXT("Planet"), TEXT("Moon"), TEXT("Asteroid")})));
		ChangesProperties->SetObjectField(TEXT("radiusKm"), BuildPatchFieldSchema(NumberSchema()));
		ChangesProperties->SetObjectField(TEXT("hasAtmosphere"), BuildPatchFieldSchema(BooleanSchema()));
		ChangesProperties->SetObjectField(TEXT("surfaceStrategy"), BuildPatchFieldSchema(
			EnumSchema({TEXT("Regional"), TEXT("SphericalContinuous")})));
		ChangesProperties->SetObjectField(TEXT("spaceTransitionStrategy"), BuildPatchFieldSchema(
			EnumSchema({TEXT("AtmosphericLoading"), TEXT("Continuous")})));
		ChangesProperties->SetObjectField(TEXT("gravityStrategy"), BuildPatchFieldSchema(
			EnumSchema({TEXT("Standard"), TEXT("Radial")})));
		ChangesProperties->SetObjectField(TEXT("surfaceGravity"), BuildPatchFieldSchema(NumberSchema()));
		ChangesProperties->SetObjectField(TEXT("parentBodyId"), BuildPatchFieldSchema(NullableStringSchema()));
		const TSharedRef<FJsonObject> ChangesSchema = ObjectSchema(
			ChangesProperties,
			{TEXT("displayName"), TEXT("semanticType"), TEXT("radiusKm"), TEXT("hasAtmosphere"),
			 TEXT("surfaceStrategy"), TEXT("spaceTransitionStrategy"), TEXT("gravityStrategy"),
			 TEXT("surfaceGravity"), TEXT("parentBodyId")});
		const TSharedRef<FJsonObject> ModifyBodyProperties = MakeShared<FJsonObject>();
		ModifyBodyProperties->SetObjectField(TEXT("targetSystemId"), StringSchema());
		ModifyBodyProperties->SetObjectField(TEXT("targetBodyId"), StringSchema());
		ModifyBodyProperties->SetObjectField(TEXT("changes"), ChangesSchema);
		const TSharedRef<FJsonObject> ModifyBodyPayload = ObjectSchema(
			ModifyBodyProperties,
			{TEXT("targetSystemId"), TEXT("targetBodyId"), TEXT("changes")});

		const TSharedRef<FJsonObject> CreateTerrainFeatureProperties = MakeShared<FJsonObject>();
		CreateTerrainFeatureProperties->SetObjectField(TEXT("targetSystemId"), StringSchema());
		CreateTerrainFeatureProperties->SetObjectField(TEXT("targetEnvironmentId"), StringSchema());
		CreateTerrainFeatureProperties->SetObjectField(TEXT("feature"), BuildTerrainFeatureSchema());
		const TSharedRef<FJsonObject> CreateTerrainFeaturePayload = ObjectSchema(
			CreateTerrainFeatureProperties,
			{TEXT("targetSystemId"), TEXT("targetEnvironmentId"), TEXT("feature")});

		const TSharedRef<FJsonObject> TerrainChangesProperties = MakeShared<FJsonObject>();
		TerrainChangesProperties->SetObjectField(TEXT("displayName"), BuildPatchFieldSchema(StringSchema()));
		TerrainChangesProperties->SetObjectField(TEXT("type"), BuildPatchFieldSchema(
			EnumSchema({TEXT("Crater"), TEXT("Canyon"), TEXT("MountainRange"), TEXT("Plain"), TEXT("Valley"), TEXT("Plateau"), TEXT("Hill")})));
		TerrainChangesProperties->SetObjectField(TEXT("position"), BuildPatchFieldSchema(BuildTerrainFeaturePositionSchema()));
		TerrainChangesProperties->SetObjectField(TEXT("sizeKm"), BuildPatchFieldSchema(NumberSchema()));
		TerrainChangesProperties->SetObjectField(TEXT("intensity"), BuildPatchFieldSchema(NumberSchema()));
		TerrainChangesProperties->SetObjectField(TEXT("environmentCenterXMeters"), BuildPatchFieldSchema(NumberSchema()));
		TerrainChangesProperties->SetObjectField(TEXT("environmentCenterYMeters"), BuildPatchFieldSchema(NumberSchema()));
		TerrainChangesProperties->SetObjectField(TEXT("radiusMeters"), BuildPatchFieldSchema(NumberSchema()));
		TerrainChangesProperties->SetObjectField(TEXT("depthMeters"), BuildPatchFieldSchema(NumberSchema()));
		TerrainChangesProperties->SetObjectField(TEXT("heightMeters"), BuildPatchFieldSchema(NumberSchema()));
		TerrainChangesProperties->SetObjectField(TEXT("falloff"), BuildPatchFieldSchema(NumberSchema()));
		TerrainChangesProperties->SetObjectField(TEXT("widthMeters"), BuildPatchFieldSchema(NumberSchema()));
		TerrainChangesProperties->SetObjectField(TEXT("compositionOrder"), BuildPatchFieldSchema(IntegerSchema()));
		TerrainChangesProperties->SetObjectField(TEXT("environmentPath"), BuildPatchFieldSchema(BuildEnvironmentTerrainPathSchema()));
		const TSharedRef<FJsonObject> TerrainChangesSchema = ObjectSchema(
			TerrainChangesProperties,
			{TEXT("displayName"), TEXT("type"), TEXT("position"), TEXT("sizeKm"), TEXT("intensity"),
			 TEXT("environmentCenterXMeters"), TEXT("environmentCenterYMeters"),
			 TEXT("radiusMeters"), TEXT("depthMeters"), TEXT("heightMeters"), TEXT("falloff"),
			 TEXT("widthMeters"), TEXT("compositionOrder"), TEXT("environmentPath")});
		const TSharedRef<FJsonObject> ModifyTerrainFeatureProperties = MakeShared<FJsonObject>();
		ModifyTerrainFeatureProperties->SetObjectField(TEXT("targetSystemId"), StringSchema());
		ModifyTerrainFeatureProperties->SetObjectField(TEXT("targetBodyId"), StringSchema());
		ModifyTerrainFeatureProperties->SetObjectField(TEXT("targetEnvironmentId"), StringSchema());
		ModifyTerrainFeatureProperties->SetObjectField(TEXT("targetFeatureId"), StringSchema());
		ModifyTerrainFeatureProperties->SetObjectField(TEXT("changes"), TerrainChangesSchema);
		const TSharedRef<FJsonObject> ModifyTerrainFeaturePayload = ObjectSchema(
			ModifyTerrainFeatureProperties,
			{TEXT("targetSystemId"), TEXT("targetBodyId"), TEXT("targetEnvironmentId"), TEXT("targetFeatureId"), TEXT("changes")});

		const TSharedRef<FJsonObject> DeleteTerrainFeatureProperties = MakeShared<FJsonObject>();
		DeleteTerrainFeatureProperties->SetObjectField(TEXT("targetSystemId"), StringSchema());
		DeleteTerrainFeatureProperties->SetObjectField(TEXT("targetBodyId"), StringSchema());
		DeleteTerrainFeatureProperties->SetObjectField(TEXT("targetEnvironmentId"), StringSchema());
		DeleteTerrainFeatureProperties->SetObjectField(TEXT("targetFeatureId"), StringSchema());
		const TSharedRef<FJsonObject> DeleteTerrainFeaturePayload = ObjectSchema(
			DeleteTerrainFeatureProperties,
			{TEXT("targetSystemId"), TEXT("targetBodyId"), TEXT("targetEnvironmentId"), TEXT("targetFeatureId")});

		const TSharedRef<FJsonObject> CreateRegionProperties = MakeShared<FJsonObject>();
		CreateRegionProperties->SetObjectField(TEXT("targetSystemId"), StringSchema());
		CreateRegionProperties->SetObjectField(TEXT("targetEnvironmentId"), StringSchema());
		CreateRegionProperties->SetObjectField(TEXT("region"), BuildRegionSchema());
		const TSharedRef<FJsonObject> CreateRegionPayload = ObjectSchema(
			CreateRegionProperties, {TEXT("targetSystemId"), TEXT("targetEnvironmentId"), TEXT("region")});

		const TSharedRef<FJsonObject> RegionChangesProperties = MakeShared<FJsonObject>();
		RegionChangesProperties->SetObjectField(TEXT("displayName"), BuildPatchFieldSchema(StringSchema()));
		RegionChangesProperties->SetObjectField(TEXT("position"), BuildPatchFieldSchema(BuildTerrainFeaturePositionSchema()));
		RegionChangesProperties->SetObjectField(TEXT("radiusKm"), BuildPatchFieldSchema(NumberSchema()));
		RegionChangesProperties->SetObjectField(TEXT("environmentCenterXMeters"), BuildPatchFieldSchema(NumberSchema()));
		RegionChangesProperties->SetObjectField(TEXT("environmentCenterYMeters"), BuildPatchFieldSchema(NumberSchema()));
		RegionChangesProperties->SetObjectField(TEXT("radiusMeters"), BuildPatchFieldSchema(NumberSchema()));
		const TSharedRef<FJsonObject> RegionChangesSchema = ObjectSchema(
			RegionChangesProperties, {TEXT("displayName"), TEXT("position"), TEXT("radiusKm"), TEXT("environmentCenterXMeters"), TEXT("environmentCenterYMeters"), TEXT("radiusMeters")});
		const TSharedRef<FJsonObject> ModifyRegionProperties = MakeShared<FJsonObject>();
		ModifyRegionProperties->SetObjectField(TEXT("targetSystemId"), StringSchema());
		ModifyRegionProperties->SetObjectField(TEXT("targetBodyId"), StringSchema());
		ModifyRegionProperties->SetObjectField(TEXT("targetEnvironmentId"), StringSchema());
		ModifyRegionProperties->SetObjectField(TEXT("targetRegionId"), StringSchema());
		ModifyRegionProperties->SetObjectField(TEXT("changes"), RegionChangesSchema);
		const TSharedRef<FJsonObject> ModifyRegionPayload = ObjectSchema(
			ModifyRegionProperties, {TEXT("targetSystemId"), TEXT("targetBodyId"), TEXT("targetEnvironmentId"), TEXT("targetRegionId"), TEXT("changes")});

		const TSharedRef<FJsonObject> CreateBiomeProperties = MakeShared<FJsonObject>();
		CreateBiomeProperties->SetObjectField(TEXT("biome"), BuildBiomeSchema());
		const TSharedRef<FJsonObject> CreateBiomePayload = ObjectSchema(CreateBiomeProperties, {TEXT("biome")});

		const TSharedRef<FJsonObject> BiomeChangesProperties = MakeShared<FJsonObject>();
		BiomeChangesProperties->SetObjectField(TEXT("displayName"), BuildPatchFieldSchema(StringSchema()));
		BiomeChangesProperties->SetObjectField(TEXT("temperature"), BuildPatchFieldSchema(NumberSchema()));
		BiomeChangesProperties->SetObjectField(TEXT("humidity"), BuildPatchFieldSchema(NumberSchema()));
		BiomeChangesProperties->SetObjectField(TEXT("vegetationLevel"), BuildPatchFieldSchema(NumberSchema()));
		BiomeChangesProperties->SetObjectField(TEXT("rockiness"), BuildPatchFieldSchema(NumberSchema()));
		const TSharedRef<FJsonObject> BiomeChangesSchema = ObjectSchema(
			BiomeChangesProperties, {TEXT("displayName"), TEXT("temperature"), TEXT("humidity"), TEXT("vegetationLevel"), TEXT("rockiness")});
		const TSharedRef<FJsonObject> ModifyBiomeProperties = MakeShared<FJsonObject>();
		ModifyBiomeProperties->SetObjectField(TEXT("targetBiomeId"), StringSchema());
		ModifyBiomeProperties->SetObjectField(TEXT("changes"), BiomeChangesSchema);
		const TSharedRef<FJsonObject> ModifyBiomePayload = ObjectSchema(
			ModifyBiomeProperties, {TEXT("targetBiomeId"), TEXT("changes")});

		const TSharedRef<FJsonObject> AssignBiomeProperties = MakeShared<FJsonObject>();
		AssignBiomeProperties->SetObjectField(TEXT("targetSystemId"), StringSchema());
		AssignBiomeProperties->SetObjectField(TEXT("targetBodyId"), StringSchema());
		AssignBiomeProperties->SetObjectField(TEXT("targetEnvironmentId"), StringSchema());
		AssignBiomeProperties->SetObjectField(TEXT("targetRegionId"), StringSchema());
		AssignBiomeProperties->SetObjectField(TEXT("biomeId"), StringSchema());
		const TSharedRef<FJsonObject> AssignBiomePayload = ObjectSchema(
			AssignBiomeProperties, {TEXT("targetSystemId"), TEXT("targetBodyId"), TEXT("targetEnvironmentId"), TEXT("targetRegionId"), TEXT("biomeId")});

		const TSharedRef<FJsonObject> CreateMaterialProperties = MakeShared<FJsonObject>();
		CreateMaterialProperties->SetObjectField(TEXT("materialFamily"), BuildMaterialFamilySchema());
		const TSharedRef<FJsonObject> CreateMaterialPayload = ObjectSchema(
			CreateMaterialProperties, {TEXT("materialFamily")});

		const TSharedRef<FJsonObject> MaterialChangesProperties = MakeShared<FJsonObject>();
		MaterialChangesProperties->SetObjectField(TEXT("displayName"), BuildPatchFieldSchema(StringSchema()));
		MaterialChangesProperties->SetObjectField(TEXT("baseColor"), BuildPatchFieldSchema(BuildMaterialColorSchema()));
		MaterialChangesProperties->SetObjectField(TEXT("roughness"), BuildPatchFieldSchema(NumberSchema()));
		MaterialChangesProperties->SetObjectField(TEXT("metallic"), BuildPatchFieldSchema(NumberSchema()));
		MaterialChangesProperties->SetObjectField(TEXT("rockiness"), BuildPatchFieldSchema(NumberSchema()));
		MaterialChangesProperties->SetObjectField(TEXT("dustiness"), BuildPatchFieldSchema(NumberSchema()));
		const TSharedRef<FJsonObject> MaterialChangesSchema = ObjectSchema(
			MaterialChangesProperties,
			{TEXT("displayName"), TEXT("baseColor"), TEXT("roughness"), TEXT("metallic"), TEXT("rockiness"), TEXT("dustiness")});
		const TSharedRef<FJsonObject> ModifyMaterialProperties = MakeShared<FJsonObject>();
		ModifyMaterialProperties->SetObjectField(TEXT("targetMaterialFamilyId"), StringSchema());
		ModifyMaterialProperties->SetObjectField(TEXT("changes"), MaterialChangesSchema);
		const TSharedRef<FJsonObject> ModifyMaterialPayload = ObjectSchema(
			ModifyMaterialProperties, {TEXT("targetMaterialFamilyId"), TEXT("changes")});

		const TSharedRef<FJsonObject> AssignMaterialRegionProperties = MakeShared<FJsonObject>();
		AssignMaterialRegionProperties->SetObjectField(TEXT("targetSystemId"), StringSchema());
		AssignMaterialRegionProperties->SetObjectField(TEXT("targetBodyId"), StringSchema());
		AssignMaterialRegionProperties->SetObjectField(TEXT("targetEnvironmentId"), StringSchema());
		AssignMaterialRegionProperties->SetObjectField(TEXT("targetRegionId"), StringSchema());
		AssignMaterialRegionProperties->SetObjectField(TEXT("materialFamilyId"), StringSchema());
		const TSharedRef<FJsonObject> AssignMaterialRegionPayload = ObjectSchema(
			AssignMaterialRegionProperties,
			{TEXT("targetSystemId"), TEXT("targetBodyId"), TEXT("targetEnvironmentId"), TEXT("targetRegionId"), TEXT("materialFamilyId")});

		const TSharedRef<FJsonObject> AssignMaterialBodyProperties = MakeShared<FJsonObject>();
		AssignMaterialBodyProperties->SetObjectField(TEXT("targetSystemId"), StringSchema());
		AssignMaterialBodyProperties->SetObjectField(TEXT("targetBodyId"), StringSchema());
		AssignMaterialBodyProperties->SetObjectField(TEXT("materialFamilyId"), StringSchema());
		const TSharedRef<FJsonObject> AssignMaterialBodyPayload = ObjectSchema(
			AssignMaterialBodyProperties, {TEXT("targetSystemId"), TEXT("targetBodyId"), TEXT("materialFamilyId")});

		const TSharedRef<FJsonObject> AssignMaterialEnvironmentProperties = MakeShared<FJsonObject>();
		AssignMaterialEnvironmentProperties->SetObjectField(TEXT("targetEnvironmentId"), StringSchema());
		AssignMaterialEnvironmentProperties->SetObjectField(TEXT("materialFamilyId"), StringSchema());
		const TSharedRef<FJsonObject> AssignMaterialEnvironmentPayload = ObjectSchema(
			AssignMaterialEnvironmentProperties, {TEXT("targetEnvironmentId"), TEXT("materialFamilyId")});

		const TSharedRef<FJsonObject> CreateEnvironmentProperties = MakeShared<FJsonObject>();
		CreateEnvironmentProperties->SetObjectField(TEXT("environment"), BuildEnvironmentSchema());
		const TSharedRef<FJsonObject> CreateEnvironmentPayload = ObjectSchema(
			CreateEnvironmentProperties, {TEXT("environment")});

		const TSharedRef<FJsonObject> EnvironmentChangesProperties = MakeShared<FJsonObject>();
		EnvironmentChangesProperties->SetObjectField(TEXT("displayName"), BuildPatchFieldSchema(StringSchema()));
		EnvironmentChangesProperties->SetObjectField(TEXT("seed"), BuildPatchFieldSchema(IntegerSchema()));
		EnvironmentChangesProperties->SetObjectField(
			TEXT("terrainProfile"),
			BuildPatchFieldSchema(EnumSchema({TEXT("flat"), TEXT("rolling"), TEXT("hills")})));
		EnvironmentChangesProperties->SetObjectField(TEXT("baseElevationMeters"), BuildPatchFieldSchema(NumberSchema()));
		EnvironmentChangesProperties->SetObjectField(TEXT("reliefAmplitudeMeters"), BuildPatchFieldSchema(NumberSchema()));
		EnvironmentChangesProperties->SetObjectField(TEXT("roughness"), BuildPatchFieldSchema(NumberSchema()));
		const TSharedRef<FJsonObject> EnvironmentChangesSchema = ObjectSchema(
			EnvironmentChangesProperties,
			{TEXT("displayName"), TEXT("seed"), TEXT("terrainProfile"),
			 TEXT("baseElevationMeters"), TEXT("reliefAmplitudeMeters"), TEXT("roughness")});
		const TSharedRef<FJsonObject> ModifyEnvironmentProperties = MakeShared<FJsonObject>();
		ModifyEnvironmentProperties->SetObjectField(TEXT("targetEnvironmentId"), StringSchema());
		ModifyEnvironmentProperties->SetObjectField(TEXT("changes"), EnvironmentChangesSchema);
		const TSharedRef<FJsonObject> ModifyEnvironmentPayload = ObjectSchema(
			ModifyEnvironmentProperties, {TEXT("targetEnvironmentId"), TEXT("changes")});

		const TSharedRef<FJsonObject> AddEnvironmentTerrainEditProperties = MakeShared<FJsonObject>();
		AddEnvironmentTerrainEditProperties->SetObjectField(TEXT("targetEnvironmentId"), StringSchema());
		AddEnvironmentTerrainEditProperties->SetObjectField(TEXT("edit"), BuildEnvironmentTerrainEditSchema());
		const TSharedRef<FJsonObject> AddEnvironmentTerrainEditPayload = ObjectSchema(
			AddEnvironmentTerrainEditProperties, {TEXT("targetEnvironmentId"), TEXT("edit")});


		const TSharedRef<FJsonObject> CreateDressingProperties = MakeShared<FJsonObject>();
		CreateDressingProperties->SetObjectField(TEXT("targetEnvironmentId"), StringSchema());
		CreateDressingProperties->SetObjectField(TEXT("dressing"), BuildEnvironmentDressingSchema());
		const TSharedRef<FJsonObject> CreateDressingPayload = ObjectSchema(
			CreateDressingProperties, {TEXT("targetEnvironmentId"), TEXT("dressing")});

		const TSharedRef<FJsonObject> DressingChangesProperties = MakeShared<FJsonObject>();
		DressingChangesProperties->SetObjectField(TEXT("displayName"), BuildPatchFieldSchema(StringSchema()));
		DressingChangesProperties->SetObjectField(TEXT("regionId"), BuildPatchFieldSchema(NullableStringSchema()));
		DressingChangesProperties->SetObjectField(TEXT("center"), BuildPatchFieldSchema(BuildDressingCenterSchema()));
		DressingChangesProperties->SetObjectField(TEXT("radiusMeters"), BuildPatchFieldSchema(NumberSchema()));
		DressingChangesProperties->SetObjectField(TEXT("categories"), BuildPatchFieldSchema(BuildDressingCategoryArraySchema()));
		DressingChangesProperties->SetObjectField(TEXT("density"), BuildPatchFieldSchema(NumberSchema()));
		DressingChangesProperties->SetObjectField(TEXT("seed"), BuildPatchFieldSchema(IntegerSchema()));
		DressingChangesProperties->SetObjectField(TEXT("slopeRange"), BuildPatchFieldSchema(BuildDressingSlopeRangeSchema()));
		DressingChangesProperties->SetObjectField(TEXT("elevationRange"), BuildPatchFieldSchema(BuildDressingElevationRangeSchema()));
		const TSharedRef<FJsonObject> DressingChangesSchema = ObjectSchema(
			DressingChangesProperties,
			{TEXT("displayName"), TEXT("regionId"), TEXT("center"), TEXT("radiusMeters"), TEXT("categories"),
			 TEXT("density"), TEXT("seed"), TEXT("slopeRange"), TEXT("elevationRange")});
		const TSharedRef<FJsonObject> ModifyDressingProperties = MakeShared<FJsonObject>();
		ModifyDressingProperties->SetObjectField(TEXT("targetEnvironmentId"), StringSchema());
		ModifyDressingProperties->SetObjectField(TEXT("targetDressingId"), StringSchema());
		ModifyDressingProperties->SetObjectField(TEXT("changes"), DressingChangesSchema);
		const TSharedRef<FJsonObject> ModifyDressingPayload = ObjectSchema(
			ModifyDressingProperties, {TEXT("targetEnvironmentId"), TEXT("targetDressingId"), TEXT("changes")});

		const TSharedRef<FJsonObject> DeleteDressingProperties = MakeShared<FJsonObject>();
		DeleteDressingProperties->SetObjectField(TEXT("targetEnvironmentId"), StringSchema());
		DeleteDressingProperties->SetObjectField(TEXT("targetDressingId"), StringSchema());
		const TSharedRef<FJsonObject> DeleteDressingPayload = ObjectSchema(
			DeleteDressingProperties, {TEXT("targetEnvironmentId"), TEXT("targetDressingId")});


		const TSharedRef<FJsonObject> CreateOverrideProperties = MakeShared<FJsonObject>();
		CreateOverrideProperties->SetObjectField(TEXT("targetEnvironmentId"), StringSchema());
		CreateOverrideProperties->SetObjectField(TEXT("override"), BuildDressingOverrideSchema());
		const TSharedRef<FJsonObject> CreateOverridePayload = ObjectSchema(CreateOverrideProperties,{TEXT("targetEnvironmentId"),TEXT("override")});

		const TSharedRef<FJsonObject> OverrideChangesProperties = MakeShared<FJsonObject>();
		OverrideChangesProperties->SetObjectField(TEXT("displayName"),BuildPatchFieldSchema(StringSchema()));
		OverrideChangesProperties->SetObjectField(TEXT("targetDressingId"),BuildPatchFieldSchema(NullableStringSchema()));
		OverrideChangesProperties->SetObjectField(TEXT("center"),BuildPatchFieldSchema(BuildDressingCenterSchema()));
		OverrideChangesProperties->SetObjectField(TEXT("radiusMeters"),BuildPatchFieldSchema(NumberSchema()));
		OverrideChangesProperties->SetObjectField(TEXT("categories"),BuildPatchFieldSchema(BuildDressingCategoryArraySchema()));
		OverrideChangesProperties->SetObjectField(TEXT("densityMultiplier"),BuildPatchFieldSchema(NumberSchema()));
		OverrideChangesProperties->SetObjectField(TEXT("exclude"),BuildPatchFieldSchema(BooleanSchema()));
		OverrideChangesProperties->SetObjectField(TEXT("seed"),BuildPatchFieldSchema(IntegerSchema()));
		const TSharedRef<FJsonObject> OverrideChangesSchema = ObjectSchema(OverrideChangesProperties,{TEXT("displayName"),TEXT("targetDressingId"),TEXT("center"),TEXT("radiusMeters"),TEXT("categories"),TEXT("densityMultiplier"),TEXT("exclude"),TEXT("seed")});
		const TSharedRef<FJsonObject> ModifyOverrideProperties = MakeShared<FJsonObject>();
		ModifyOverrideProperties->SetObjectField(TEXT("targetEnvironmentId"),StringSchema()); ModifyOverrideProperties->SetObjectField(TEXT("targetOverrideId"),StringSchema()); ModifyOverrideProperties->SetObjectField(TEXT("changes"),OverrideChangesSchema);
		const TSharedRef<FJsonObject> ModifyOverridePayload = ObjectSchema(ModifyOverrideProperties,{TEXT("targetEnvironmentId"),TEXT("targetOverrideId"),TEXT("changes")});
		const TSharedRef<FJsonObject> DeleteOverrideProperties = MakeShared<FJsonObject>();
		DeleteOverrideProperties->SetObjectField(TEXT("targetEnvironmentId"),StringSchema()); DeleteOverrideProperties->SetObjectField(TEXT("targetOverrideId"),StringSchema());
		const TSharedRef<FJsonObject> DeleteOverridePayload = ObjectSchema(DeleteOverrideProperties,{TEXT("targetEnvironmentId"),TEXT("targetOverrideId")});

		const TSharedRef<FJsonObject> CreateGeometryProperties = MakeShared<FJsonObject>();
		CreateGeometryProperties->SetObjectField(TEXT("targetEnvironmentId"),StringSchema()); CreateGeometryProperties->SetObjectField(TEXT("geometry"),BuildGeometrySchema());
		const TSharedRef<FJsonObject> CreateGeometryPayload = ObjectSchema(CreateGeometryProperties,{TEXT("targetEnvironmentId"),TEXT("geometry")});
		const TSharedRef<FJsonObject> Dimensions = MakeShared<FJsonObject>(); Dimensions->SetObjectField(TEXT("widthMeters"),NumberSchema()); Dimensions->SetObjectField(TEXT("depthMeters"),NumberSchema()); Dimensions->SetObjectField(TEXT("heightMeters"),NumberSchema());
		const TSharedRef<FJsonObject> DimensionsSchema = ObjectSchema(Dimensions,{TEXT("widthMeters"),TEXT("depthMeters"),TEXT("heightMeters")});
		const TSharedRef<FJsonObject> GeometryChangesProperties = MakeShared<FJsonObject>();
		GeometryChangesProperties->SetObjectField(TEXT("displayName"),BuildPatchFieldSchema(StringSchema())); GeometryChangesProperties->SetObjectField(TEXT("type"),BuildPatchFieldSchema(EnumSchema({TEXT("Cliff"),TEXT("Overhang"),TEXT("Arch"),TEXT("RockPillar"),TEXT("RockFormation")})));
		GeometryChangesProperties->SetObjectField(TEXT("center"),BuildPatchFieldSchema(BuildDressingCenterSchema())); GeometryChangesProperties->SetObjectField(TEXT("elevationOffsetMeters"),BuildPatchFieldSchema(NumberSchema()));
		GeometryChangesProperties->SetObjectField(TEXT("dimensions"),BuildPatchFieldSchema(DimensionsSchema)); GeometryChangesProperties->SetObjectField(TEXT("yawDegrees"),BuildPatchFieldSchema(NumberSchema())); GeometryChangesProperties->SetObjectField(TEXT("seed"),BuildPatchFieldSchema(IntegerSchema())); GeometryChangesProperties->SetObjectField(TEXT("assetId"),BuildPatchFieldSchema(StringSchema()));
		const TSharedRef<FJsonObject> GeometryChangesSchema = ObjectSchema(GeometryChangesProperties,{TEXT("displayName"),TEXT("type"),TEXT("center"),TEXT("elevationOffsetMeters"),TEXT("dimensions"),TEXT("yawDegrees"),TEXT("seed"),TEXT("assetId")});
		const TSharedRef<FJsonObject> ModifyGeometryProperties = MakeShared<FJsonObject>(); ModifyGeometryProperties->SetObjectField(TEXT("targetEnvironmentId"),StringSchema()); ModifyGeometryProperties->SetObjectField(TEXT("targetGeometryId"),StringSchema()); ModifyGeometryProperties->SetObjectField(TEXT("changes"),GeometryChangesSchema);
		const TSharedRef<FJsonObject> ModifyGeometryPayload = ObjectSchema(ModifyGeometryProperties,{TEXT("targetEnvironmentId"),TEXT("targetGeometryId"),TEXT("changes")});
		const TSharedRef<FJsonObject> DeleteGeometryProperties = MakeShared<FJsonObject>(); DeleteGeometryProperties->SetObjectField(TEXT("targetEnvironmentId"),StringSchema()); DeleteGeometryProperties->SetObjectField(TEXT("targetGeometryId"),StringSchema());
		const TSharedRef<FJsonObject> DeleteGeometryPayload = ObjectSchema(DeleteGeometryProperties,{TEXT("targetEnvironmentId"),TEXT("targetGeometryId")});

		const TSharedRef<FJsonObject> CommandItems = MakeShared<FJsonObject>();
		CommandItems->SetArrayField(
			TEXT("anyOf"),
			{MakeShared<FJsonValueObject>(BuildCommandSchema(TEXT("CreateSystem"), CreateSystemPayload)),
			 MakeShared<FJsonValueObject>(BuildCommandSchema(TEXT("CreateBody"), CreateBodyPayload)),
			 MakeShared<FJsonValueObject>(BuildCommandSchema(TEXT("ModifyBody"), ModifyBodyPayload)),
			 MakeShared<FJsonValueObject>(BuildCommandSchema(TEXT("CreateTerrainFeature"), CreateTerrainFeaturePayload)),
			 MakeShared<FJsonValueObject>(BuildCommandSchema(TEXT("ModifyTerrainFeature"), ModifyTerrainFeaturePayload)),
			 MakeShared<FJsonValueObject>(BuildCommandSchema(TEXT("DeleteTerrainFeature"), DeleteTerrainFeaturePayload)),
			 MakeShared<FJsonValueObject>(BuildCommandSchema(TEXT("CreateRegion"), CreateRegionPayload)),
			 MakeShared<FJsonValueObject>(BuildCommandSchema(TEXT("ModifyRegion"), ModifyRegionPayload)),
			 MakeShared<FJsonValueObject>(BuildCommandSchema(TEXT("CreateBiome"), CreateBiomePayload)),
			 MakeShared<FJsonValueObject>(BuildCommandSchema(TEXT("ModifyBiome"), ModifyBiomePayload)),
			 MakeShared<FJsonValueObject>(BuildCommandSchema(TEXT("AssignBiomeToRegion"), AssignBiomePayload)),
			 MakeShared<FJsonValueObject>(BuildCommandSchema(TEXT("CreateMaterialFamily"), CreateMaterialPayload)),
			 MakeShared<FJsonValueObject>(BuildCommandSchema(TEXT("ModifyMaterialFamily"), ModifyMaterialPayload)),
			 MakeShared<FJsonValueObject>(BuildCommandSchema(TEXT("AssignMaterialToRegion"), AssignMaterialRegionPayload)),
			 MakeShared<FJsonValueObject>(BuildCommandSchema(TEXT("AssignMaterialToBody"), AssignMaterialBodyPayload)),
			 MakeShared<FJsonValueObject>(BuildCommandSchema(TEXT("AssignMaterialToEnvironment"), AssignMaterialEnvironmentPayload)),
			 MakeShared<FJsonValueObject>(BuildCommandSchema(TEXT("CreateEnvironment"), CreateEnvironmentPayload)),
			 MakeShared<FJsonValueObject>(BuildCommandSchema(TEXT("ModifyEnvironment"), ModifyEnvironmentPayload)),
			 MakeShared<FJsonValueObject>(BuildCommandSchema(TEXT("AddEnvironmentTerrainEdit"), AddEnvironmentTerrainEditPayload)),
			 MakeShared<FJsonValueObject>(BuildCommandSchema(TEXT("CreateEnvironmentDressing"), CreateDressingPayload)),
			 MakeShared<FJsonValueObject>(BuildCommandSchema(TEXT("ModifyEnvironmentDressing"), ModifyDressingPayload)),
			 MakeShared<FJsonValueObject>(BuildCommandSchema(TEXT("DeleteEnvironmentDressing"), DeleteDressingPayload)),
			 MakeShared<FJsonValueObject>(BuildCommandSchema(TEXT("CreateEnvironmentDressingOverride"), CreateOverridePayload)),
			 MakeShared<FJsonValueObject>(BuildCommandSchema(TEXT("ModifyEnvironmentDressingOverride"), ModifyOverridePayload)),
			 MakeShared<FJsonValueObject>(BuildCommandSchema(TEXT("DeleteEnvironmentDressingOverride"), DeleteOverridePayload)),
			 MakeShared<FJsonValueObject>(BuildCommandSchema(TEXT("CreateEnvironmentGeometry"), CreateGeometryPayload)),
			 MakeShared<FJsonValueObject>(BuildCommandSchema(TEXT("ModifyEnvironmentGeometry"), ModifyGeometryPayload)),
			 MakeShared<FJsonValueObject>(BuildCommandSchema(TEXT("DeleteEnvironmentGeometry"), DeleteGeometryPayload))});
		const TSharedRef<FJsonObject> CommandsSchema = MakeShared<FJsonObject>();
		CommandsSchema->SetStringField(TEXT("type"), TEXT("array"));
		CommandsSchema->SetObjectField(TEXT("items"), CommandItems);

		const TSharedRef<FJsonObject> VersionSchema = MakeShared<FJsonObject>();
		VersionSchema->SetStringField(TEXT("type"), TEXT("integer"));
		VersionSchema->SetArrayField(
			TEXT("enum"),
			{MakeShared<FJsonValueNumber>(FWorldDirectorCommandProposalParser::CurrentSchemaVersion)});
		const TSharedRef<FJsonObject> RootProperties = MakeShared<FJsonObject>();
		RootProperties->SetObjectField(TEXT("schemaVersion"), VersionSchema);
		RootProperties->SetObjectField(
			TEXT("status"),
			EnumSchema({TEXT("ready"), TEXT("needs_clarification"), TEXT("unsupported_runtime_capability"), TEXT("out_of_domain")}));
		RootProperties->SetObjectField(TEXT("summary"), StringSchema());
		RootProperties->SetObjectField(TEXT("mode"), EnumSchema({TEXT("direct"), TEXT("build_plan")}));
		RootProperties->SetObjectField(TEXT("commands"), CommandsSchema);
		RootProperties->SetObjectField(TEXT("buildPlan"), BuildWorldBuildPlanSchema());
		return ObjectSchema(
			RootProperties,
			{TEXT("schemaVersion"), TEXT("status"), TEXT("summary"), TEXT("mode"), TEXT("commands"), TEXT("buildPlan")});
	}

	const TCHAR* SemanticTypeName(EWorldDirectorCelestialBodySemanticType Value)
	{
		switch (Value)
		{
		case EWorldDirectorCelestialBodySemanticType::Moon: return TEXT("Moon");
		case EWorldDirectorCelestialBodySemanticType::Asteroid: return TEXT("Asteroid");
		default: return TEXT("Planet");
		}
	}

	const TCHAR* SurfaceStrategyName(EWorldDirectorSurfaceStrategy Value)
	{
		return Value == EWorldDirectorSurfaceStrategy::SphericalContinuous
			? TEXT("SphericalContinuous")
			: TEXT("Regional");
	}

	const TCHAR* SpaceTransitionStrategyName(EWorldDirectorSpaceTransitionStrategy Value)
	{
		return Value == EWorldDirectorSpaceTransitionStrategy::Continuous
			? TEXT("Continuous")
			: TEXT("AtmosphericLoading");
	}

	const TCHAR* GravityStrategyName(EWorldDirectorGravityStrategy Value)
	{
		return Value == EWorldDirectorGravityStrategy::Radial
			? TEXT("Radial")
			: TEXT("Standard");
	}

	FString DescribeRuntimeRequirements(const FWorldDirectorCelestialBodyDefinition& Body)
	{
		TArray<FString> Names;
		for (const EWorldDirectorRuntimeCapability Capability
			: FWorldDirectorRuntimeCapabilityCatalog::GetEffectiveRequirements(Body))
		{
			Names.Add(FWorldDirectorRuntimeCapabilityCatalog::CapabilityName(Capability));
		}
		return Names.IsEmpty() ? FString(TEXT("none")) : FString::Join(Names, TEXT(","));
	}

	const TCHAR* TerrainFeatureTypeName(EWorldDirectorTerrainFeatureType Value)
	{
		return FWorldDirectorTerrainFeatureCatalog::TypeName(Value);
	}


	FString SerializeJson(const TSharedRef<FJsonObject>& Object)
	{
		FString Result;
		const TSharedRef<TJsonWriter<TCHAR, TCondensedJsonPrintPolicy<TCHAR>>> Writer =
			TJsonWriterFactory<TCHAR, TCondensedJsonPrintPolicy<TCHAR>>::Create(&Result);
		FJsonSerializer::Serialize(Object, Writer);
		return Result;
	}

	bool TryGetResponseId(const TSharedPtr<FJsonObject>& Object, int64& OutId)
	{
		double NumericId = 0.0;
		if (!Object.IsValid() || !Object->TryGetNumberField(TEXT("id"), NumericId))
		{
			return false;
		}
		OutId = static_cast<int64>(NumericId);
		return true;
	}

	FString GetErrorMessage(const TSharedPtr<FJsonObject>& Object)
	{
		const TSharedPtr<FJsonObject>* ErrorObject = nullptr;
		if (Object.IsValid() && Object->TryGetObjectField(TEXT("error"), ErrorObject) && ErrorObject && ErrorObject->IsValid())
		{
			FString Message;
			if ((*ErrorObject)->TryGetStringField(TEXT("message"), Message))
			{
				return Message;
			}
		}
		return TEXT("Erreur App Server sans diagnostic.");
	}

}

FString FWorldDirectorCodexProtocol::BuildContextBlock(
	const FWorldDirectorWorldDefinition& World,
	const FWorldDirectorContextState& Context,
	const FWorldDirectorSpatialContextState& SpatialContext)
{
	const FWorldDirectorContextState Normalized =
		FWorldDirectorContextManager::NormalizeForWorld(Context, World);
	const FWorldDirectorSpatialContextState NormalizedSpatial =
		FWorldDirectorSpatialContextResolver::NormalizeForWorld(SpatialContext, World);
	TArray<FString> Lines;
	Lines.Add(TEXT("Current World Context"));
	Lines.Add(TEXT(""));
	Lines.Add(TEXT("Environments:"));
	if (World.Environments.IsEmpty())
	{
		Lines.Add(TEXT("- none"));
	}
	else
	{
		for (const FWorldDirectorEnvironmentDefinition& Environment : World.Environments)
		{
			if (Environment.bHasTerrain)
			{
				Lines.Add(FString::Printf(
					TEXT("- %s - %s - seed=%d - material=%s - terrain=%s requested=%.2fx%.2fm materialized=%.2fx%.2fm base=%.2fm amplitude=%.2fm roughness=%.3f resolution=%dx%d edits=%d features=%d regions=%d dressings=%d overrides=%d geometry=%d"),
					*Environment.PersistentId.ToString(),
					*Environment.DisplayName,
					Environment.Seed,
					Environment.MaterialFamilyId.IsValid() ? *Environment.MaterialFamilyId.ToString() : TEXT("default"),
					*Environment.Terrain.GetProfileName(),
					Environment.Terrain.RequestedWidthMeters,
					Environment.Terrain.RequestedHeightMeters,
					Environment.Terrain.GetMaterializedWidthMeters(),
					Environment.Terrain.GetMaterializedHeightMeters(),
					Environment.Terrain.BaseElevationMeters,
					Environment.Terrain.ReliefAmplitudeMeters,
					Environment.Terrain.Roughness,
					Environment.Terrain.GetVertexCountX(),
					Environment.Terrain.GetVertexCountY(),
					Environment.Terrain.Edits.Num(),
					Environment.TerrainFeatures.Num(),
					Environment.Regions.Num(),
					Environment.Dressings.Num(),
					Environment.DressingOverrides.Num(),
					Environment.NonHeightfieldGeometry.Num()));
				Lines.Add(FString::Printf(
					TEXT("  logicalFrame=center=(0,0)m boundsX=[%.2f,%.2f]m boundsY=[%.2f,%.2f]m cardinal=west(-X),east(+X),south(-Y),north(+Y)"),
					-Environment.Terrain.RequestedWidthMeters * 0.5,
					Environment.Terrain.RequestedWidthMeters * 0.5,
					-Environment.Terrain.RequestedHeightMeters * 0.5,
					Environment.Terrain.RequestedHeightMeters * 0.5));
				for (int32 EditIndex = 0; EditIndex < Environment.Terrain.Edits.Num(); ++EditIndex)
				{
					const FWorldDirectorEnvironmentTerrainEditDefinition& Edit = Environment.Terrain.Edits[EditIndex];
					Lines.Add(FString::Printf(
						TEXT("  edit[%d]=%s center=(%.3f,%.3f)m radius=%.3fm amount=%.3fm targetElevation=%.3fm strength=%.3f falloff=%.3f"),
						EditIndex,
						*Edit.GetTypeName(),
						Edit.CenterXMeters,
						Edit.CenterYMeters,
						Edit.RadiusMeters,
						Edit.AmountMeters,
						Edit.TargetElevationMeters,
						Edit.Strength,
						Edit.Falloff));
				}
				for (const FWorldDirectorTerrainFeatureDefinition& Feature : Environment.TerrainFeatures)
				{
					Lines.Add(FString::Printf(
						TEXT("  feature=%s name=%s type=%s order=%d center=(%.3f,%.3f)m radius=%.3fm width=%.3fm depth=%.3fm height=%.3fm falloff=%.3f intensity=%.3f pathPoints=%d"),
						*Feature.PersistentId.ToString(),
						*Feature.DisplayName,
						TerrainFeatureTypeName(Feature.Type),
						Feature.CompositionOrder,
						Feature.EnvironmentCenterXMeters,
						Feature.EnvironmentCenterYMeters,
						Feature.RadiusMeters,
						Feature.WidthMeters,
						Feature.DepthMeters,
						Feature.HeightMeters,
						Feature.Falloff,
						Feature.Intensity,
						Feature.EnvironmentPath.Num()));
					if (FWorldDirectorTerrainFeatureCatalog::GetEnvironmentSpatialMode(Feature.Type)
						== EWorldDirectorEnvironmentTerrainFeatureSpatialMode::Path)
					{
						for (int32 PathIndex = 0; PathIndex < Feature.EnvironmentPath.Num(); ++PathIndex)
						{
							const FWorldDirectorEnvironmentTerrainPathPoint& Point = Feature.EnvironmentPath[PathIndex];
							Lines.Add(FString::Printf(TEXT("    path[%d]=(%.3f,%.3f)m"), PathIndex, Point.XMeters, Point.YMeters));
						}
					}
				}

				for (const FWorldDirectorEnvironmentDressingDefinition& Dressing : Environment.Dressings)
				{
					TArray<FString> CategoryNames;
					for (const EWorldDirectorEnvironmentDressingCategory Category : Dressing.Categories)
					{
						switch (Category)
						{
						case EWorldDirectorEnvironmentDressingCategory::Trees: CategoryNames.Add(TEXT("Trees")); break;
						case EWorldDirectorEnvironmentDressingCategory::Bushes: CategoryNames.Add(TEXT("Bushes")); break;
						case EWorldDirectorEnvironmentDressingCategory::Grass: CategoryNames.Add(TEXT("Grass")); break;
						case EWorldDirectorEnvironmentDressingCategory::Stones: CategoryNames.Add(TEXT("Stones")); break;
						case EWorldDirectorEnvironmentDressingCategory::Rocks: CategoryNames.Add(TEXT("Rocks")); break;
						default: break;
						}
					}
					Lines.Add(FString::Printf(
						TEXT("  dressing=%s name=%s region=%s center=(%.3f,%.3f)m radius=%.3fm density=%.3f seed=%d categories=%s slope=[%.1f,%.1f] elevation=[%.1f,%.1f]m"),
						*Dressing.PersistentId.ToString(), *Dressing.DisplayName,
						Dressing.RegionId.IsValid() ? *Dressing.RegionId.ToString() : TEXT("none"),
						Dressing.CenterXMeters, Dressing.CenterYMeters, Dressing.RadiusMeters,
						Dressing.Density, Dressing.Seed, *FString::Join(CategoryNames, TEXT(",")),
						Dressing.MinSlopeDegrees, Dressing.MaxSlopeDegrees,
						Dressing.MinElevationMeters, Dressing.MaxElevationMeters));
				}
				for (const FWorldDirectorEnvironmentDressingOverrideDefinition& Override : Environment.DressingOverrides)
				{
					Lines.Add(FString::Printf(
						TEXT("  dressingOverride=%s name=%s targetDressing=%s center=(%.3f,%.3f)m radius=%.3fm multiplier=%.3f exclude=%s seed=%d"),
						*Override.PersistentId.ToString(), *Override.DisplayName,
						Override.TargetDressingId.IsValid() ? *Override.TargetDressingId.ToString() : TEXT("all"),
						Override.CenterXMeters, Override.CenterYMeters, Override.RadiusMeters, Override.DensityMultiplier,
						Override.bExclude ? TEXT("true") : TEXT("false"), Override.Seed));
				}
				for (const FWorldDirectorEnvironmentGeometryDefinition& Geometry : Environment.NonHeightfieldGeometry)
				{
					const TCHAR* TypeName = TEXT("Cliff");
					switch (Geometry.Type)
					{
					case EWorldDirectorEnvironmentGeometryType::Cliff: TypeName = TEXT("Cliff"); break;
					case EWorldDirectorEnvironmentGeometryType::Overhang: TypeName = TEXT("Overhang"); break;
					case EWorldDirectorEnvironmentGeometryType::Arch: TypeName = TEXT("Arch"); break;
					case EWorldDirectorEnvironmentGeometryType::RockPillar: TypeName = TEXT("RockPillar"); break;
					case EWorldDirectorEnvironmentGeometryType::RockFormation: TypeName = TEXT("RockFormation"); break;
					}
					Lines.Add(FString::Printf(
						TEXT("  geometry=%s name=%s type=%s center=(%.3f,%.3f)m elevationOffset=%.3fm size=(%.3f,%.3f,%.3f)m yaw=%.1f seed=%d assetId=%s"),
						*Geometry.PersistentId.ToString(), *Geometry.DisplayName, TypeName, Geometry.CenterXMeters, Geometry.CenterYMeters,
						Geometry.ElevationOffsetMeters, Geometry.WidthMeters, Geometry.DepthMeters, Geometry.HeightMeters, Geometry.YawDegrees,
						Geometry.Seed, *Geometry.AssetId));
				}


			}
			else
			{
				Lines.Add(FString::Printf(
					TEXT("- %s - %s - seed=%d - material=%s - terrain=none"),
					*Environment.PersistentId.ToString(),
					*Environment.DisplayName,
					Environment.Seed,
					Environment.MaterialFamilyId.IsValid() ? *Environment.MaterialFamilyId.ToString() : TEXT("default")));
			}
		}
	}

	Lines.Add(TEXT(""));
	Lines.Add(TEXT("Systems:"));
	if (World.Systems.IsEmpty())
	{
		Lines.Add(TEXT("- none"));
	}
	else
	{
		for (const FWorldDirectorCelestialSystemDefinition& System : World.Systems)
		{
			Lines.Add(FString::Printf(
				TEXT("- %s - %s"),
				*System.PersistentId.ToString(),
				*System.DisplayName));
		}
	}

	Lines.Add(TEXT(""));
	Lines.Add(TEXT("Bodies:"));
	bool bHasBodies = false;
	for (const FWorldDirectorCelestialSystemDefinition& System : World.Systems)
	{
		for (const FWorldDirectorCelestialBodyDefinition& Body : System.Bodies)
		{
			bHasBodies = true;
			Lines.Add(FString::Printf(
				TEXT("- %s - %s - system=%s - radiusKm=%s - atmosphere=%s - surface=%s - transition=%s - gravity=%s - parent=%s - material=%s - runtimeRequirements=%s"),
				*Body.PersistentId.ToString(),
				SemanticTypeName(Body.SemanticType),
				*System.PersistentId.ToString(),
				*FString::SanitizeFloat(Body.RadiusKm),
				Body.bHasAtmosphere ? TEXT("true") : TEXT("false"),
				SurfaceStrategyName(Body.SurfaceStrategy),
				SpaceTransitionStrategyName(Body.SpaceTransitionStrategy),
				GravityStrategyName(Body.GravityStrategy),
				Body.ParentBodyId.IsValid() ? *Body.ParentBodyId.ToString() : TEXT("none"),
				Body.MaterialFamilyId.IsValid() ? *Body.MaterialFamilyId.ToString() : TEXT("none"),
				*DescribeRuntimeRequirements(Body)));
		}
	}
	if (!bHasBodies)
	{
		Lines.Add(TEXT("- none"));
	}

	Lines.Add(TEXT(""));
	Lines.Add(TEXT("TerrainFeatures:"));
	bool bHasFeatures = false;
	for (const FWorldDirectorCelestialSystemDefinition& System : World.Systems)
	{
		for (const FWorldDirectorCelestialBodyDefinition& Body : System.Bodies)
		{
			for (const FWorldDirectorTerrainFeatureDefinition& Feature : Body.TerrainFeatures)
			{
				bHasFeatures = true;
				Lines.Add(FString::Printf(
					TEXT("- %s - %s - body=%s - sizeKm=%s - intensity=%s - position=(lat=%s,lon=%s,elevationKm=%s)"),
					*Feature.PersistentId.ToString(),
					TerrainFeatureTypeName(Feature.Type),
					*Body.PersistentId.ToString(),
					*FString::SanitizeFloat(Feature.SizeKm),
					*FString::SanitizeFloat(Feature.Intensity),
					*FString::SanitizeFloat(Feature.Position.LatitudeDeg),
					*FString::SanitizeFloat(Feature.Position.LongitudeDeg),
					*FString::SanitizeFloat(Feature.Position.ElevationKm)));
			}
		}
	}
	if (!bHasFeatures)
	{
		Lines.Add(TEXT("- none"));
	}

	Lines.Add(TEXT(""));
	Lines.Add(TEXT("Regions:"));
	bool bHasRegions = false;
	for (const FWorldDirectorEnvironmentDefinition& Environment : World.Environments)
	{
		for (const FWorldDirectorRegionDefinition& Region : Environment.Regions)
		{
			bHasRegions = true;
			Lines.Add(FString::Printf(
				TEXT("- %s - environment=%s - radiusMeters=%s - biome=%s - material=%s - center=(xMeters=%s,yMeters=%s)"),
				*Region.PersistentId.ToString(), *Environment.PersistentId.ToString(),
				*FString::SanitizeFloat(Region.RadiusMeters),
				Region.BiomeId.IsValid() ? *Region.BiomeId.ToString() : TEXT("none"),
				Region.MaterialFamilyId.IsValid() ? *Region.MaterialFamilyId.ToString() : TEXT("none"),
				*FString::SanitizeFloat(Region.EnvironmentCenterXMeters),
				*FString::SanitizeFloat(Region.EnvironmentCenterYMeters)));
		}
	}
	for (const FWorldDirectorCelestialSystemDefinition& System : World.Systems)
	{
		for (const FWorldDirectorCelestialBodyDefinition& Body : System.Bodies)
		{
			for (const FWorldDirectorRegionDefinition& Region : Body.Regions)
			{
				bHasRegions = true;
				Lines.Add(FString::Printf(
					TEXT("- %s - body=%s - radiusKm=%s - biome=%s - material=%s - position=(lat=%s,lon=%s,elevationKm=%s)"),
					*Region.PersistentId.ToString(), *Body.PersistentId.ToString(),
					*FString::SanitizeFloat(Region.RadiusKm),
					Region.BiomeId.IsValid() ? *Region.BiomeId.ToString() : TEXT("none"),
					Region.MaterialFamilyId.IsValid() ? *Region.MaterialFamilyId.ToString() : TEXT("none"),
					*FString::SanitizeFloat(Region.Position.LatitudeDeg),
					*FString::SanitizeFloat(Region.Position.LongitudeDeg),
					*FString::SanitizeFloat(Region.Position.ElevationKm)));
			}
		}
	}
	if (!bHasRegions) { Lines.Add(TEXT("- none")); }

	Lines.Add(TEXT(""));
	Lines.Add(TEXT("Biomes:"));
	if (World.Biomes.IsEmpty())
	{
		Lines.Add(TEXT("- none"));
	}
	else
	{
		for (const FWorldDirectorBiomeDefinition& Biome : World.Biomes)
		{
			Lines.Add(FString::Printf(
				TEXT("- %s - temperature=%s - humidity=%s - vegetation=%s - rockiness=%s"),
				*Biome.PersistentId.ToString(), *FString::SanitizeFloat(Biome.Temperature),
				*FString::SanitizeFloat(Biome.Humidity), *FString::SanitizeFloat(Biome.VegetationLevel),
				*FString::SanitizeFloat(Biome.Rockiness)));
		}
	}

	Lines.Add(TEXT(""));
	Lines.Add(TEXT("MaterialFamilies:"));
	if (World.MaterialFamilies.IsEmpty())
	{
		Lines.Add(TEXT("- none"));
	}
	else
	{
		for (const FWorldDirectorMaterialFamilyDefinition& Material : World.MaterialFamilies)
		{
			Lines.Add(FString::Printf(
				TEXT("- %s - color=(%s,%s,%s) - roughness=%s - metallic=%s - rockiness=%s - dustiness=%s"),
				*Material.PersistentId.ToString(),
				*FString::SanitizeFloat(Material.BaseColor.Red),
				*FString::SanitizeFloat(Material.BaseColor.Green),
				*FString::SanitizeFloat(Material.BaseColor.Blue),
				*FString::SanitizeFloat(Material.Roughness),
				*FString::SanitizeFloat(Material.Metallic),
				*FString::SanitizeFloat(Material.Rockiness),
				*FString::SanitizeFloat(Material.Dustiness)));
		}
	}

	const FWorldDirectorRuntimeCapabilities RuntimeCapabilities =
		FWorldDirectorRuntimeCapabilityCatalog::GetCurrentNullOnCapabilities();
	Lines.Add(TEXT(""));
	Lines.Add(TEXT("RuntimeCapabilities:"));
	for (const EWorldDirectorRuntimeCapability Capability
		: FWorldDirectorRuntimeCapabilityCatalog::GetOrderedCapabilities())
	{
		Lines.Add(FString::Printf(
			TEXT("- %s=%s"),
			FWorldDirectorRuntimeCapabilityCatalog::CapabilityName(Capability),
			FWorldDirectorRuntimeCapabilityCatalog::SupportName(RuntimeCapabilities.Get(Capability))));
	}

	Lines.Add(TEXT(""));
	Lines.Add(TEXT("CurrentWorldMissingRuntimeCapabilities:"));
	const TArray<FWorldDirectorMissingRuntimeCapability> MissingCapabilities =
		FWorldDirectorRuntimeCapabilityCatalog::DiagnoseMissingCapabilities(World, RuntimeCapabilities);
	if (MissingCapabilities.IsEmpty())
	{
		Lines.Add(TEXT("- none"));
	}
	else
	{
		for (const FWorldDirectorMissingRuntimeCapability& Missing : MissingCapabilities)
		{
			TArray<FString> BodyIds;
			for (const FWorldDirectorPersistentId& BodyId : Missing.RequiredByBodies)
			{
				BodyIds.Add(BodyId.ToString());
			}
			Lines.Add(FString::Printf(
				TEXT("- %s - requiredBy=%s"),
				FWorldDirectorRuntimeCapabilityCatalog::CapabilityName(Missing.Capability),
				*FString::Join(BodyIds, TEXT(","))));
		}
	}

	auto OptionalId = [](const FWorldDirectorPersistentId& Id)
	{
		return Id.IsValid() ? Id.ToString() : FString(TEXT("none"));
	};
	Lines.Add(TEXT(""));
	Lines.Add(FString::Printf(TEXT("LastCreatedSystem: %s"), *OptionalId(Normalized.LastCreatedSystemId)));
	Lines.Add(FString::Printf(TEXT("LastCreatedBody: %s"), *OptionalId(Normalized.LastCreatedBodyId)));
	Lines.Add(FString::Printf(TEXT("LastModifiedBody: %s"), *OptionalId(Normalized.LastModifiedBodyId)));
	Lines.Add(FString::Printf(TEXT("LastAffectedBody: %s"), *OptionalId(Normalized.LastAffectedBodyId)));
	Lines.Add(FString::Printf(TEXT("LastCreatedFeature: %s"), *OptionalId(Normalized.LastCreatedFeatureId)));
	Lines.Add(FString::Printf(TEXT("LastModifiedFeature: %s"), *OptionalId(Normalized.LastModifiedFeatureId)));
	Lines.Add(FString::Printf(TEXT("LastAffectedFeature: %s"), *OptionalId(Normalized.LastAffectedFeatureId)));
	Lines.Add(FString::Printf(TEXT("LastCreatedRegion: %s"), *OptionalId(Normalized.LastCreatedRegionId)));
	Lines.Add(FString::Printf(TEXT("LastModifiedRegion: %s"), *OptionalId(Normalized.LastModifiedRegionId)));
	Lines.Add(FString::Printf(TEXT("LastAffectedRegion: %s"), *OptionalId(Normalized.LastAffectedRegionId)));
	Lines.Add(FString::Printf(TEXT("LastCreatedBiome: %s"), *OptionalId(Normalized.LastCreatedBiomeId)));
	Lines.Add(FString::Printf(TEXT("LastModifiedBiome: %s"), *OptionalId(Normalized.LastModifiedBiomeId)));
	Lines.Add(FString::Printf(TEXT("LastAffectedBiome: %s"), *OptionalId(Normalized.LastAffectedBiomeId)));
	Lines.Add(FString::Printf(TEXT("LastCreatedMaterial: %s"), *OptionalId(Normalized.LastCreatedMaterialFamilyId)));
	Lines.Add(FString::Printf(TEXT("LastModifiedMaterial: %s"), *OptionalId(Normalized.LastModifiedMaterialFamilyId)));
	Lines.Add(FString::Printf(TEXT("LastAffectedMaterial: %s"), *OptionalId(Normalized.LastAffectedMaterialFamilyId)));
	Lines.Add(FString::Printf(TEXT("LastCreatedDressing: %s"), *OptionalId(Normalized.LastCreatedDressingId)));
	Lines.Add(FString::Printf(TEXT("LastModifiedDressing: %s"), *OptionalId(Normalized.LastModifiedDressingId)));
	Lines.Add(FString::Printf(TEXT("LastAffectedDressing: %s"), *OptionalId(Normalized.LastAffectedDressingId)));
	Lines.Add(FString::Printf(TEXT("LastCreatedDressingOverride: %s"), *OptionalId(Normalized.LastCreatedDressingOverrideId)));
	Lines.Add(FString::Printf(TEXT("LastModifiedDressingOverride: %s"), *OptionalId(Normalized.LastModifiedDressingOverrideId)));
	Lines.Add(FString::Printf(TEXT("LastAffectedDressingOverride: %s"), *OptionalId(Normalized.LastAffectedDressingOverrideId)));
	Lines.Add(FString::Printf(TEXT("LastCreatedGeometry: %s"), *OptionalId(Normalized.LastCreatedGeometryId)));
	Lines.Add(FString::Printf(TEXT("LastModifiedGeometry: %s"), *OptionalId(Normalized.LastModifiedGeometryId)));
	Lines.Add(FString::Printf(TEXT("LastAffectedGeometry: %s"), *OptionalId(Normalized.LastAffectedGeometryId)));
	Lines.Add(TEXT(""));
	Lines.Add(TEXT("EnvironmentAssetCatalog:"));
	Lines.Add(FWorldDirectorEnvironmentAssetCatalog::BuildLlmSummary());
	Lines.Add(FString::Printf(TEXT("SelectedRegion: %s"), *OptionalId(Normalized.SelectedRegionId)));
	Lines.Add(FString::Printf(TEXT("SelectedSystem: %s"), *OptionalId(Normalized.SelectedSystemId)));
	Lines.Add(FString::Printf(TEXT("SelectedBody: %s"), *OptionalId(Normalized.SelectedBodyId)));

	Lines.Add(TEXT(""));
	Lines.Add(TEXT("EnvironmentTerrainFeatureReferences:"));
	const EWorldDirectorTerrainFeatureType ReferenceTypes[] = {
		EWorldDirectorTerrainFeatureType::Crater,
		EWorldDirectorTerrainFeatureType::Canyon,
		EWorldDirectorTerrainFeatureType::MountainRange,
		EWorldDirectorTerrainFeatureType::Valley,
		EWorldDirectorTerrainFeatureType::Plateau,
		EWorldDirectorTerrainFeatureType::Hill,
		EWorldDirectorTerrainFeatureType::Plain};
	for (const EWorldDirectorTerrainFeatureType FeatureType : ReferenceTypes)
	{
		const FWorldDirectorEnvironmentFeatureReferenceResolution Reference =
			FWorldDirectorContextManager::ResolveEnvironmentTerrainFeatureReference(
				Normalized,
				World,
				FeatureType,
				NormalizedSpatial.SelectedFeatureId);
		const TCHAR* FeatureTypeName = TerrainFeatureTypeName(FeatureType);
		if (Reference.Status == EWorldDirectorEnvironmentFeatureReferenceStatus::Resolved)
		{
			const FWorldDirectorEnvironmentDefinition* ReferenceEnvironment = World.FindEnvironment(Reference.EnvironmentId);
			const FWorldDirectorTerrainFeatureDefinition* Feature = ReferenceEnvironment
				? ReferenceEnvironment->FindTerrainFeature(Reference.FeatureId)
				: nullptr;
			Lines.Add(FString::Printf(
				TEXT("- type=%s status=resolved source=%s environment=%s feature=%s radiusMeters=%s widthMeters=%s depthMeters=%s heightMeters=%s falloff=%s intensity=%s"),
				FeatureTypeName,
				FWorldDirectorContextManager::ReferenceSourceName(Reference.Source),
				*Reference.EnvironmentId.ToString(),
				*Reference.FeatureId.ToString(),
				Feature ? *FString::SanitizeFloat(Feature->RadiusMeters) : TEXT("unknown"),
				Feature ? *FString::SanitizeFloat(Feature->WidthMeters) : TEXT("unknown"),
				Feature ? *FString::SanitizeFloat(Feature->DepthMeters) : TEXT("unknown"),
				Feature ? *FString::SanitizeFloat(Feature->HeightMeters) : TEXT("unknown"),
				Feature ? *FString::SanitizeFloat(Feature->Falloff) : TEXT("unknown"),
				Feature ? *FString::SanitizeFloat(Feature->Intensity) : TEXT("unknown")));
		}
		else if (Reference.Status == EWorldDirectorEnvironmentFeatureReferenceStatus::Ambiguous)
		{
			TArray<FString> CandidateIds;
			for (const FWorldDirectorPersistentId& CandidateId : Reference.CandidateFeatureIds)
			{
				CandidateIds.Add(CandidateId.ToString());
			}
			Lines.Add(FString::Printf(
				TEXT("- type=%s status=ambiguous candidates=%s"),
				FeatureTypeName,
				*FString::Join(CandidateIds, TEXT(","))));
		}
		else
		{
			Lines.Add(FString::Printf(TEXT("- type=%s status=none"), FeatureTypeName));
		}
	}

	Lines.Add(TEXT(""));
	Lines.Add(TEXT("SpatialContext:"));
	Lines.Add(FString::Printf(TEXT("TargetEnvironment: %s"), *OptionalId(NormalizedSpatial.TargetEnvironmentId)));
	if (NormalizedSpatial.HasEnvironmentTarget())
	{
		Lines.Add(FString::Printf(
			TEXT("TargetEnvironmentPosition: xMeters=%s, yMeters=%s, elevationMeters=%s"),
			*FString::SanitizeFloat(NormalizedSpatial.TargetEnvironmentPosition.XMeters),
			*FString::SanitizeFloat(NormalizedSpatial.TargetEnvironmentPosition.YMeters),
			*FString::SanitizeFloat(NormalizedSpatial.TargetEnvironmentPosition.ElevationMeters)));
	}
	else
	{
		Lines.Add(TEXT("TargetEnvironmentPosition: none"));
	}
	Lines.Add(FString::Printf(TEXT("TargetSystem: %s"), *OptionalId(NormalizedSpatial.TargetSystemId)));
	Lines.Add(FString::Printf(TEXT("TargetBody: %s"), *OptionalId(NormalizedSpatial.TargetBodyId)));
	if (NormalizedSpatial.HasPlanetTarget())
	{
		Lines.Add(FString::Printf(
			TEXT("TargetPosition: latitudeDeg=%s, longitudeDeg=%s, elevationKm=%s"),
			*FString::SanitizeFloat(NormalizedSpatial.TargetPosition.LatitudeDeg),
			*FString::SanitizeFloat(NormalizedSpatial.TargetPosition.LongitudeDeg),
			*FString::SanitizeFloat(NormalizedSpatial.TargetPosition.ElevationKm)));
	}
	else
	{
		Lines.Add(TEXT("TargetPosition: none"));
	}
	Lines.Add(FString::Printf(TEXT("SelectedFeature: %s"), *OptionalId(NormalizedSpatial.SelectedFeatureId)));
	Lines.Add(FString::Printf(TEXT("SelectedRegion: %s"), *OptionalId(NormalizedSpatial.SelectedRegionId)));
	if (NormalizedSpatial.bHasCanyonStart)
	{
		Lines.Add(FString::Printf(
			TEXT("LinearFeatureStart: environment=%s xMeters=%s yMeters=%s elevationMeters=%s"),
			*NormalizedSpatial.CanyonStartEnvironmentId.ToString(),
			*FString::SanitizeFloat(NormalizedSpatial.CanyonStartPosition.XMeters),
			*FString::SanitizeFloat(NormalizedSpatial.CanyonStartPosition.YMeters),
			*FString::SanitizeFloat(NormalizedSpatial.CanyonStartPosition.ElevationMeters)));
	}
	else
	{
		Lines.Add(TEXT("LinearFeatureStart: none"));
	}
	if (NormalizedSpatial.bHasCanyonEnd)
	{
		Lines.Add(FString::Printf(
			TEXT("LinearFeatureEnd: environment=%s xMeters=%s yMeters=%s elevationMeters=%s"),
			*NormalizedSpatial.CanyonEndEnvironmentId.ToString(),
			*FString::SanitizeFloat(NormalizedSpatial.CanyonEndPosition.XMeters),
			*FString::SanitizeFloat(NormalizedSpatial.CanyonEndPosition.YMeters),
			*FString::SanitizeFloat(NormalizedSpatial.CanyonEndPosition.ElevationMeters)));
	}
	else
	{
		Lines.Add(TEXT("LinearFeatureEnd: none"));
	}
	Lines.Add(FString::Printf(TEXT("LinearFeaturePathReady: %s"), NormalizedSpatial.HasLinearFeaturePath() ? TEXT("true") : TEXT("false")));
	Lines.Add(FString::Printf(
		TEXT("Source: %s"),
		FWorldDirectorSpatialContextResolver::SourceName(NormalizedSpatial.Source)));
	return FString::Join(Lines, LINE_TERMINATOR);
}

bool FWorldDirectorCodexProtocol::BeginPrompt(
	const FString& Prompt,
	const FWorldDirectorWorldDefinition& World,
	const FWorldDirectorContextState& Context,
	const FWorldDirectorSpatialContextState& SpatialContext,
	TArray<FString>& OutMessages,
	FWorldDirectorAIResponse& OutFailure)
{
	if (IsBusy())
	{
		OutFailure = FWorldDirectorAIResponse::Failure(
			EWorldDirectorAIResultCode::Busy,
			TEXT("Codex traite déjà une requête."));
		return false;
	}

	if (Prompt.TrimStartAndEnd().IsEmpty())
	{
		OutFailure = FWorldDirectorAIResponse::Failure(
			EWorldDirectorAIResultCode::InvalidPrompt,
			TEXT("Le prompt est vide."));
		return false;
	}

	PendingPrompt = Prompt;
	PendingWorldContext = BuildContextBlock(World, Context, SpatialContext);
	TurnId.Reset();
	FinalAgentMessage.Reset();

	if (State == EState::Ready && !ThreadId.IsEmpty())
	{
		QueueTurnStart(OutMessages);
		return true;
	}

	const TSharedRef<FJsonObject> ClientInfo = MakeShared<FJsonObject>();
	ClientInfo->SetStringField(TEXT("name"), TEXT("NullOn World Director"));
	ClientInfo->SetStringField(TEXT("version"), TEXT("0.1.0"));

	const TSharedRef<FJsonObject> Params = MakeShared<FJsonObject>();
	Params->SetObjectField(TEXT("clientInfo"), ClientInfo);
	PendingRequestId = NextRequestId++;
	OutMessages.Add(MakeRequest(TEXT("initialize"), Params, PendingRequestId));
	State = EState::WaitingInitialize;
	return true;
}

bool FWorldDirectorCodexProtocol::HandleServerLine(
	const FString& Line,
	TArray<FString>& OutMessages,
	FWorldDirectorAIResponse& OutCompletion,
	bool& bOutCompleted)
{
	bOutCompleted = false;
	TSharedPtr<FJsonObject> Message;
	const TSharedRef<TJsonReader<>> Reader = TJsonReaderFactory<>::Create(Line);
	if (!FJsonSerializer::Deserialize(Reader, Message) || !Message.IsValid())
	{
		return CompleteFailure(
			EWorldDirectorAIResultCode::ProtocolError,
			TEXT("Codex App Server a envoyé une ligne JSON invalide."),
			OutCompletion,
			bOutCompleted);
	}

	int64 ResponseId = 0;
	if (TryGetResponseId(Message, ResponseId))
	{
		if (ResponseId != PendingRequestId)
		{
			return true;
		}

		if (Message->HasField(TEXT("error")))
		{
			const FString ErrorMessage = GetErrorMessage(Message);
			return CompleteFailure(
				IsAuthenticationError(ErrorMessage)
					? EWorldDirectorAIResultCode::AuthenticationRequired
					: EWorldDirectorAIResultCode::AppServerError,
				ErrorMessage,
				OutCompletion,
				bOutCompleted);
		}

		const TSharedPtr<FJsonObject>* Result = nullptr;
		if (!Message->TryGetObjectField(TEXT("result"), Result) || !Result || !Result->IsValid())
		{
			return CompleteFailure(
				EWorldDirectorAIResultCode::ProtocolError,
				TEXT("Réponse App Server incomplète : champ result absent."),
				OutCompletion,
				bOutCompleted);
		}

		switch (State)
		{
		case EState::WaitingInitialize:
			OutMessages.Add(MakeNotification(TEXT("initialized")));
			QueueThreadStart(OutMessages);
			return true;

		case EState::WaitingThread:
		{
			const TSharedPtr<FJsonObject>* Thread = nullptr;
			if (!(*Result)->TryGetObjectField(TEXT("thread"), Thread)
				|| !Thread || !Thread->IsValid()
				|| !(*Thread)->TryGetStringField(TEXT("id"), ThreadId)
				|| ThreadId.IsEmpty())
			{
				return CompleteFailure(
					EWorldDirectorAIResultCode::ProtocolError,
					TEXT("Codex n'a pas retourné de threadId valide."),
					OutCompletion,
					bOutCompleted);
			}
			QueueTurnStart(OutMessages);
			return true;
		}

		case EState::WaitingTurnStart:
		{
			const TSharedPtr<FJsonObject>* Turn = nullptr;
			if (!(*Result)->TryGetObjectField(TEXT("turn"), Turn)
				|| !Turn || !Turn->IsValid()
				|| !(*Turn)->TryGetStringField(TEXT("id"), TurnId)
				|| TurnId.IsEmpty())
			{
				return CompleteFailure(
					EWorldDirectorAIResultCode::ProtocolError,
					TEXT("Codex n'a pas retourné de turnId valide."),
					OutCompletion,
					bOutCompleted);
			}
			State = EState::WaitingTurnCompletion;
			return true;
		}

		default:
			return true;
		}
	}

	FString Method;
	if (!Message->TryGetStringField(TEXT("method"), Method))
	{
		return true;
	}

	const TSharedPtr<FJsonObject>* Params = nullptr;
	if (!Message->TryGetObjectField(TEXT("params"), Params) || !Params || !Params->IsValid())
	{
		return true;
	}

	if (Method == TEXT("item/completed"))
	{
		FString MessageThreadId;
		FString MessageTurnId;
		const TSharedPtr<FJsonObject>* Item = nullptr;
		if ((*Params)->TryGetStringField(TEXT("threadId"), MessageThreadId)
			&& (*Params)->TryGetStringField(TEXT("turnId"), MessageTurnId)
			&& MessageThreadId == ThreadId
			&& MessageTurnId == TurnId
			&& (*Params)->TryGetObjectField(TEXT("item"), Item)
			&& Item && Item->IsValid())
		{
			FString Type;
			if ((*Item)->TryGetStringField(TEXT("type"), Type) && Type == TEXT("agentMessage"))
			{
				(*Item)->TryGetStringField(TEXT("text"), FinalAgentMessage);
			}
		}
		return true;
	}

	if (Method == TEXT("error"))
	{
		FString MessageThreadId;
		FString MessageTurnId;
		if ((*Params)->TryGetStringField(TEXT("threadId"), MessageThreadId) && MessageThreadId != ThreadId)
		{
			return true;
		}
		if ((*Params)->TryGetStringField(TEXT("turnId"), MessageTurnId) && !TurnId.IsEmpty() && MessageTurnId != TurnId)
		{
			return true;
		}

		bool bWillRetry = false;
		(*Params)->TryGetBoolField(TEXT("willRetry"), bWillRetry);
		if (bWillRetry)
		{
			return true;
		}

		FString ErrorMessage = TEXT("Erreur Codex App Server.");
		const TSharedPtr<FJsonObject>* Error = nullptr;
		if ((*Params)->TryGetObjectField(TEXT("error"), Error) && Error && Error->IsValid())
		{
			(*Error)->TryGetStringField(TEXT("message"), ErrorMessage);
		}
		return CompleteFailure(
			IsAuthenticationError(ErrorMessage)
				? EWorldDirectorAIResultCode::AuthenticationRequired
				: EWorldDirectorAIResultCode::AppServerError,
			ErrorMessage,
			OutCompletion,
			bOutCompleted);
	}

	if (Method == TEXT("turn/completed"))
	{
		FString MessageThreadId;
		const TSharedPtr<FJsonObject>* Turn = nullptr;
		FString MessageTurnId;
		FString TurnStatus;
		if (!(*Params)->TryGetStringField(TEXT("threadId"), MessageThreadId)
			|| MessageThreadId != ThreadId
			|| !(*Params)->TryGetObjectField(TEXT("turn"), Turn)
			|| !Turn || !Turn->IsValid()
			|| !(*Turn)->TryGetStringField(TEXT("id"), MessageTurnId)
			|| MessageTurnId != TurnId)
		{
			return true;
		}

		(*Turn)->TryGetStringField(TEXT("status"), TurnStatus);
		if (TurnStatus != TEXT("completed"))
		{
			return CompleteFailure(
				EWorldDirectorAIResultCode::AppServerError,
				FString::Printf(TEXT("Le turn Codex s'est terminé avec le statut '%s'."), *TurnStatus),
				OutCompletion,
				bOutCompleted);
		}

		bOutCompleted = true;
		const bool bValidResponse = ParseStructuredResponse(OutCompletion);
		State = EState::Ready;
		PendingPrompt.Reset();
		PendingWorldContext.Reset();
		PendingRequestId = 0;
		return bValidResponse;
	}

	return true;
}

void FWorldDirectorCodexProtocol::HandleTransportFailure(
	EWorldDirectorAIResultCode Code,
	const FString& Diagnostic,
	FWorldDirectorAIResponse& OutCompletion)
{
	OutCompletion = FWorldDirectorAIResponse::Failure(Code, Diagnostic);
	OutCompletion.ThreadId = ThreadId;
	OutCompletion.TurnId = TurnId;
	Reset();
}

void FWorldDirectorCodexProtocol::Reset()
{
	State = EState::Disconnected;
	PendingRequestId = 0;
	PendingPrompt.Reset();
	PendingWorldContext.Reset();
	ThreadId.Reset();
	TurnId.Reset();
	FinalAgentMessage.Reset();
}

bool FWorldDirectorCodexProtocol::IsBusy() const
{
	return State != EState::Disconnected && State != EState::Ready;
}

FString FWorldDirectorCodexProtocol::MakeRequest(
	const FString& Method,
	const TSharedRef<FJsonObject>& Params,
	int64 RequestId) const
{
	const TSharedRef<FJsonObject> Request = MakeShared<FJsonObject>();
	Request->SetNumberField(TEXT("id"), RequestId);
	Request->SetStringField(TEXT("method"), Method);
	Request->SetObjectField(TEXT("params"), Params);
	return SerializeJson(Request);
}

FString FWorldDirectorCodexProtocol::MakeNotification(const FString& Method) const
{
	const TSharedRef<FJsonObject> Notification = MakeShared<FJsonObject>();
	Notification->SetStringField(TEXT("method"), Method);
	return SerializeJson(Notification);
}

void FWorldDirectorCodexProtocol::QueueThreadStart(TArray<FString>& OutMessages)
{
	const TSharedRef<FJsonObject> Params = MakeShared<FJsonObject>();
	Params->SetStringField(TEXT("cwd"), CodexWorkingDirectory());
	Params->SetStringField(TEXT("approvalPolicy"), TEXT("never"));
	Params->SetStringField(TEXT("sandbox"), TEXT("read-only"));
	Params->SetBoolField(TEXT("ephemeral"), true);
	FString DeveloperInstructions =
		TEXT("Tu proposes exclusivement des commandes semantiques World Director en JSON v6. Le champ status vaut uniquement ready, needs_clarification, unsupported_runtime_capability ou out_of_domain. Commandes autorisees : "
			"CreateSystem, CreateBody, ModifyBody, CreateTerrainFeature, ModifyTerrainFeature, DeleteTerrainFeature, CreateRegion, ModifyRegion, "
			"CreateBiome, ModifyBiome, AssignBiomeToRegion, CreateMaterialFamily, ModifyMaterialFamily, AssignMaterialToRegion, "
			"AssignMaterialToBody, AssignMaterialToEnvironment, CreateEnvironment, ModifyEnvironment, AddEnvironmentTerrainEdit, CreateEnvironmentDressing, ModifyEnvironmentDressing, DeleteEnvironmentDressing, CreateEnvironmentDressingOverride, ModifyEnvironmentDressingOverride, DeleteEnvironmentDressingOverride, CreateEnvironmentGeometry, ModifyEnvironmentGeometry et DeleteEnvironmentGeometry. Le WorldState et Current World Context sont la seule source de verite. "
			"Une demande de terrain classique, sol, Landscape ou environnement terrestre non spherique doit utiliser CreateEnvironment, jamais CreateBody. "
			"CreateEnvironment fournit persistentId, displayName, seed et terrain={widthMeters,heightMeters,profile,baseElevationMeters,reliefAmplitudeMeters,roughness}. "
			"Profils terrain autorises : flat, rolling, hills. Pour flat utilise reliefAmplitudeMeters=0 et roughness=0. Pour un terrain legerement vallonne, utilise rolling avec environ 15 m d'amplitude et roughness 0.25. Pour quelques collines, utilise hills avec environ 60 m d'amplitude et roughness 0.40. "
			"Si une demande simple de terrain n'indique aucune dimension, utilise 2000 x 2000 m. Pour '2 km x 2 km', utilise 2000 et 2000. baseElevationMeters vaut 0 sauf demande contraire. "
			"Pour modifier un Environment existant entre flat, rolling et hills, utilise ModifyEnvironment et renseigne ensemble terrainProfile, reliefAmplitudeMeters et roughness afin que l'etat final soit valide. Si la demande parle du terrain existant et qu'un seul Environment avec terrain existe dans Current World Context, cible cet Environment ; s'il y en a plusieurs sans cible univoque, retourne needs_clarification. "
			"WD-029 composition: TerrainEdits restent appliques avant les TerrainFeatures. Chaque TerrainFeature Environment possede un compositionOrder entier; pour une creation normale mets compositionOrder=-1 afin que World Director l ajoute automatiquement en fin de composition. ModifyTerrainFeature peut fixer compositionOrder a une valeur finale >= 0 pour reordonner generiquement sans changer le PersistentId. Pour supprimer une feature existante, utilise uniquement DeleteTerrainFeature avec le meme targetEnvironmentId/targetFeatureId (ou la cible body legacy); ne remplace jamais une suppression par une sculpture inverse. Pour 'Supprime ce canyon' ou 'Supprime cette colline', prefere SelectedFeature puis LastAffectedFeature lorsque leur type correspond; si la cible reste ambigue, retourne needs_clarification. "
			"Pour une sculpture locale du vrai terrain Environment, utilise uniquement AddEnvironmentTerrainEdit avec edit={type,centerXMeters,centerYMeters,radiusMeters,amountMeters,targetElevationMeters,strength,falloff}; types autorises Raise, Lower, Flatten et Smooth. N'utilise jamais CreateTerrainFeature pour Raise/Lower/Flatten/Smooth et n'appelle jamais directement Landscape. Pour une feature geographique reelle Environment, utilise le meme CreateTerrainFeature generique avec targetEnvironmentId, targetSystemId vide et bodyId vide. Types reels autorises sur Environment : Crater, Canyon, MountainRange, Valley, Plateau, Hill et Plain. Tous les champs generiques du schema feature restent explicites : center, radius, width, depth, height, falloff, intensity et environmentPath ; mets 0 ou [] pour les parametres inutilises par le type. Pour 'Cree un cratere ici', copie exactement TargetEnvironmentPosition x/y et utilise radiusMeters=120, depthMeters=20, heightMeters=0, falloff=0.65. Pour 'Cree un canyon d'ici jusque-la', utilise LinearFeatureStart/End dans cet ordre, widthMeters=160, depthMeters=35, heightMeters=0, falloff=0.65. Pour 'Cree une chaine de montagnes d'ici jusque-la', utilise le meme path, widthMeters=260, heightMeters=90, depthMeters=0, falloff=0.75. Pour 'Cree une vallee d'ici jusque-la', utilise le meme path, widthMeters=320, depthMeters=28, heightMeters=0, falloff=0.90. Pour 'Cree un plateau ici', copie TargetEnvironmentPosition, radiusMeters=180, heightMeters=45, depthMeters=0, falloff=0.55. Pour 'Ajoute une colline ici', utilise radiusMeters=120, heightMeters=35, depthMeters=0, falloff=0.85. Pour 'Cree une zone relativement plate ici', cree une TerrainFeature Plain avec radiusMeters=160, depthMeters=0, heightMeters=0, falloff=0.70 et intensity=0.75. Reserve AddEnvironmentTerrainEdit Flatten aux formulations de sculpture comme 'Aplatis cette zone'. N'invente aucun point intermediaire pour les features lineaires WD-028. "
			"Pour modifier conversationnellement une TerrainFeature Environment existante, utilise exclusivement ModifyTerrainFeature sur le meme targetFeatureId et le meme targetEnvironmentId : ne cree jamais une nouvelle feature et n'ajoute jamais un TerrainEdit pour simuler la modification d'une feature existante. EnvironmentTerrainFeatureReferences est la resolution autoritative, par type, pour les references generiques et pronoms. Si la ligne du type vise a status=resolved, cible exactement feature/environment indiques. Si status=none ou status=ambiguous, retourne needs_clarification avec commands vide, sauf si l'utilisateur donne explicitement un ID de feature. Les changements sont des valeurs finales absolues dans ModifyTerrainFeature, jamais des multiplicateurs implicites. Pour un Canyon : 'Rends-le plus profond' sans valeur chiffree propose depth final = 1.25 fois la profondeur actuelle ; 'Double sa largeur' donne exactement 2 fois la largeur actuelle ; 'Elargis-le encore un peu' utilise 1.25 fois la largeur actuelle ; 'Rends les parois moins abruptes' augmente falloff de 0.20 sans depasser 1.0 et demande clarification si falloff vaut deja 1.0. Combine dans une seule commande ModifyTerrainFeature les changements portant sur la meme feature lorsque cela reste lisible. La validation World Director reste autoritative sur les bornes finales. "
			"Pour 'ici', 'cet endroit', 'cette position' ou une feature locale sur un Environment, SpatialContext.TargetEnvironment et SpatialContext.TargetEnvironmentPosition sont la seule source autorisee. Copie exactement xMeters et yMeters sans les inventer ni les arrondir. Pour Flatten, copie aussi elevationMeters comme targetElevationMeters. Sans TargetEnvironmentPosition valide, retourne status=needs_clarification et commands vide. Pour une feature lineaire Canyon, MountainRange ou Valley demandee 'd'ici jusque-la', utilise uniquement LinearFeatureStart/LinearFeatureEnd ; sans LinearFeaturePathReady=true retourne status=needs_clarification et commands vide. "
			"Valeurs par defaut pour une demande moderee sans chiffres : radiusMeters=100 et falloff=0.5. Raise/Lower utilisent amountMeters=8, strength=1 et targetElevationMeters=0. Flatten utilise amountMeters=0, strength=1 et targetElevationMeters issu du contexte. Smooth utilise amountMeters=0, targetElevationMeters=0 et strength=0.65. Ces valeurs restent explicites dans la commande. "
			"N'invente aucun parametre Landscape technique : World Director derive seul la topologie Unreal valide, le scale et la materialisation. Utilise des IDs stables Environment_001, Environment_002, etc. "
			"Avant tout CreateSystem, inspecte Systems et Bodies dans Current World Context. Si un body explicitement reference existe deja, "
			"son champ system= est autoritatif : pour creer un enfant autour de ce body, utilise exactement ce system comme targetSystemId et "
			"n'emets aucun CreateSystem. N'emets CreateSystem que si la demande cree explicitement un nouveau systeme ou si aucun systeme "
			"existant approprie n'est disponible et qu'aucune cible existante ne fixe deja le systeme. Ne cree jamais un systeme arbitraire uniquement "
			"pour accompagner une creation sous un body existant. "
			"Tolere les fautes de frappe, abreviations et formulations familieres ou incompletes lorsque l'intention et la cible restent univoques dans le contexte (par exemple 'rend la lune bcp plus petite' ou 'agrandi le cratere qu'on vient de faire'). "
			"Ne corrige jamais une vraie ambiguite par supposition : si plusieurs objets correspondent raisonnablement et qu'aucune selection, dernier objet affecte ou autre contexte ne tranche, retourne status=needs_clarification avec commands vide. "
			"Pour une demande contradictoire, n'ignore silencieusement aucun morceau : si une interpretation coherente est possible, explique-la explicitement dans summary et ne propose que cette interpretation ; sinon retourne status=needs_clarification avec commands vide. "
			"Une reference explicitement nommee mais inexistante doit rester une commande ciblee sur cet ID afin que la validation World Director la rejette explicitement ; n'invente pas un remplacement. "
			"Pour les astres, prefere SelectedBody puis LastAffectedBody. Pour les features, prefere SelectedFeature puis LastAffectedFeature. "
			"Pour une reference de region telle que 'cette zone' ou 'cette region', prefere SpatialContext.SelectedRegion lorsqu'il existe, "
			"sinon SelectedRegion puis LastAffectedRegion. N'invente jamais une cible en cas d'ambiguite. Le bloc SpatialContext est la seule source "
			"autorisee pour 'ici' et expressions equivalentes. Une cible explicitement nommee par ID doit produire une commande meme si cet ID "
			"n'existe pas : World Director reste seul responsable de la validation. Pour CreateRegion ou CreateTerrainFeature a 'ici' sur une planete, copie "
			"exactement TargetSystem, TargetBody et TargetPosition dans la commande ; n'invente ni n'arrondis la position. Pour une TerrainFeature planetaire, targetEnvironmentId reste vide, compositionOrder=-1 et les autres champs Environment du schema feature restent a leurs valeurs neutres. Pour une sculpture ou une TerrainFeature locale Environment a 'ici', utilise exclusivement TargetEnvironment et TargetEnvironmentPosition comme defini plus haut. Pour une TerrainFeature lineaire d'ici jusque-la, utilise exclusivement LinearFeatureStart/LinearFeatureEnd et leur Environment commun. Sans SpatialContext "
			"valide, retourne status=needs_clarification et commands vide. CreateRegion utilise une seule forme spatiale. Sur une planete : targetSystemId/bodyId/position/radiusKm sont renseignes et targetEnvironmentId/environmentId/radiusMeters valent vide/0. Sur un Environment Landscape : targetEnvironmentId et region.environmentId valent exactement SpatialContext.TargetEnvironment, bodyId et targetSystemId restent vides, environmentCenterXMeters/environmentCenterYMeters recopient exactement TargetEnvironmentPosition x/y, radiusMeters=150 par defaut, tandis que position et radiusKm restent neutres. "
			"Pour modifier une Region Environment existante, conserve son persistentId et utilise ModifyRegion avec targetEnvironmentId ; ne recree jamais une region lorsque LastAffectedRegion ou une region unique du contexte resout la cible. "
			"Utilise des IDs stables Region_001, Biome_001, Material_001, etc. Les valeurs biome "
			"temperature, humidity, vegetationLevel et rockiness sont normalisees entre 0 et 1. Profils indicatifs : "
			"Temperate=(0.55,0.60,0.70,0.30), Arid=(0.75,0.15,0.10,0.55), Rocky=(0.45,0.25,0.15,0.90), "
			"Cold=(0.15,0.35,0.20,0.65). Sur un Environment avec TargetEnvironmentPosition valide, 'Cette zone doit etre plus aride' cree une Region Environment a cet endroit si aucune region existante n'est resolue, puis cree/assigne un biome Arid dans le meme plan. Si une region sans biome doit devenir aride/rocheuse, propose CreateBiome puis "
			"AssignBiomeToRegion dans le meme plan. Si elle a deja un biome, utilise ModifyBiome et ne cree pas de doublon inutile. "
			"Le dressing Environment est distinct du profil abstrait du biome. 'Mets un peu plus de nature dans cette zone' doit utiliser CreateEnvironmentDressing ou ModifyEnvironmentDressing. Il faut un SpatialContext TargetEnvironment avec TargetEnvironmentPosition valide, ou une Region Environment explicitement selectionnee. Si LastAffectedDressing designe un dressing existant du meme Environment et que la reference est univoque, utilise ModifyEnvironmentDressing avec exactement le meme targetDressingId et augmente moderement density, typiquement +0.15 sans depasser 1.0. Sinon cree un dressing avec ID stable Dressing_001, Dressing_002, etc., categories=[Trees,Bushes,Grass,Stones,Rocks], density=0.55, seed entier explicite stable, radiusMeters=150, slope=[0,70], elevation=[-10000,10000]. Si une Region Environment est explicitement selectionnee, regionId cible cette Region ; sinon regionId=null et centerXMeters/centerYMeters recopient exactement TargetEnvironmentPosition. N'invente jamais un chemin d'asset Unreal : le choix d'asset est exclusivement controle par World Director. Une intention portant seulement sur le climat ou le niveau abstrait de vegetation d'un biome peut utiliser ModifyBiome. "
			"Pour les modifications locales du dressing, utilise CreateEnvironmentDressingOverride ou ModifyEnvironmentDressingOverride, jamais un systeme specifique par categorie. 'Moins d'arbres ici' => categories=[Trees], densityMultiplier=0.35, exclude=false. 'Ajoute davantage de rochers au pied de cette falaise' => categories=[Rocks,Stones], densityMultiplier=1.8, exclude=false. 'Garde ce passage degage' => categories=[Trees,Bushes,Grass,Stones,Rocks], densityMultiplier=0.0, exclude=true. Le centre recopie exactement SpatialContext.TargetEnvironmentPosition et radiusMeters=40 par defaut. Si LastAffectedDressingOverride cible le meme Environment et que la reference est univoque, conserve exactement son ID avec ModifyEnvironmentDressingOverride. "
			"Les falaises verticales, surplombs, arches, piliers/pics et formations rocheuses non-heightfield utilisent CreateEnvironmentGeometry/ModifyEnvironmentGeometry/DeleteEnvironmentGeometry. Types autorises: Cliff, Overhang, Arch, RockPillar, RockFormation. Pour une demande locale contenant 'ici', 'a cet endroit' ou equivalente, la position recopie exactement TargetEnvironmentPosition et son absence impose needs_clarification. En revanche, une demande de disposition globale ou relative dans un Environment, par exemple 'mets une falaise de chaque cote', n'exige PAS TargetEnvironmentPosition si un seul Environment avec terrain est une cible univoque. Utilise alors son repere logique centre en (0,0), avec ouest=x negatif, est=x positif, sud=y negatif et nord=y positif; les limites sont +/- requestedWidthMeters/2 en X et +/- requestedHeightMeters/2 en Y. Pour 'une falaise de chaque cote' sans autre reference spatiale exploitable, interprete les deux cotes comme ouest/est et place deux Cliff symetriques autour du centre avec x=-0.30*requestedWidthMeters et x=+0.30*requestedWidthMeters, y=0, en restant dans les limites de l'Environment. Si l'utilisateur ne donne pas de dimensions, utilise des dimensions moderees sans demander clarification; pour un Environment 2000x2000m, prends par defaut widthMeters=600, depthMeters=80, heightMeters=120, elevationOffsetMeters=0 et yawDegrees=90 afin que les falaises s'etendent nord-sud. Adapte seulement la longueur a la taille du terrain si celui-ci est nettement plus petit. Choisis les premiers IDs Geometry_NNN libres apres inspection des geometries existantes; s'il n'y en a aucune, utilise Geometry_001 puis Geometry_002. Utilise des seeds stables distincts derives du seed de l'Environment, par exemple EnvironmentSeed+1 et EnvironmentSeed+2. Si une unique TerrainFeature lineaire Valley ou Canyon constitue clairement la reference, prefere ses donnees reelles (path/width) et place les deux falaises de part et d'autre de son axe plutot que d'utiliser le fallback ouest/est. L'absence de falaise existante n'est jamais une ambiguite pour une intention de creation: zero falaise + 'une falaise de chaque cote' signifie creer deux falaises. Une formulation de cardinalite exacte comme 'une seule falaise de chaque cote' vise exactement deux Cliff logiques dans l'Environment cible: inspecte les EnvironmentGeometry existantes; s'il y en a zero cree-en deux, s'il y en a plus de deux conserve/modifie une entite pertinente par cote et supprime les Cliff excedentaires, sans demander une clarification uniquement a cause du nombre existant. Pour une creation, assetId peut etre vide afin que World Director resolve automatiquement une representation controlee depuis EnvironmentAssetCatalog; sinon utilise uniquement un AssetId logique compatible du catalogue, jamais un chemin Unreal. Aucun cube/BasicShape visible ne doit servir de fallback naturel. Conserve LastAffectedGeometry lors d'une modification univoque. "
			"Les champs assetIds de dressing contiennent uniquement des AssetIds listes dans EnvironmentAssetCatalog. N'invente jamais /Game/... ni /Engine/... dans une commande structuree. Un AssetId inconnu doit rester invalide; aucun fallback arbitraire. "
			"Les familles de materiaux utilisent baseColor.red/green/blue, roughness, metallic, rockiness et dustiness, tous normalises entre 0 et 1. "
			"Les intentions visuelles sombre/clair/gris/mat/brillant/poussiereux et rocheux lorsqu'elles decrivent l'aspect du sol ou d'une zone "
			"doivent utiliser MaterialFamily, pas ModifyBiome ; le biome reste reserve aux intentions climat/nature/temperature/humidite. "
			"Priorite visuelle : le materiau explicitement assigne a une Region surcharge celui du Body ; le materiau du Body est le fallback. "
			"Pour modifier visuellement une region, cible d'abord la Region selectionnee/derniere region affectee. Si elle a son propre material, utilise "
			"ModifyMaterialFamily. Si elle n'a pas de material de region, cree une nouvelle MaterialFamily puis AssignMaterialToRegion dans le meme plan ; "
			"ne modifie pas le material herite du Body car cela affecterait d'autres zones. Si un Body cible a deja un material, modifie-le ; sinon cree "
			"une MaterialFamily puis AssignMaterialToBody. Pour un Environment Landscape, MaterialFamilyId dans le contexte indique sa surface. 'Rends le terrain plus rocheux' signifie modifier Rockiness de cette MaterialFamily via ModifyMaterialFamily ; si material=default, cree une MaterialFamily puis AssignMaterialToEnvironment dans le meme plan. S'il existe plusieurs Environments avec terrain et qu'aucune cible n'est univoque, retourne needs_clarification au lieu de choisir arbitrairement. "
			"'Rends le sol plus poussiereux' signifie augmenter Dustiness. Le backend Surface utilise ces parametres de maniere generique sur le terrain final (pente/bruit de surface), jamais selon le type Canyon/MountainRange/etc. 'Plus sombre et rocheuse' signifie diminuer raisonnablement les composantes BaseColor et augmenter "
			"Rockiness, avec Roughness optionnelle si cela aide l'intention. 'Plus poussiereuse, mais garde la couleur actuelle' signifie augmenter seulement "
			"Dustiness : baseColor.isSet=false et les autres proprietes non demandees restent isSet=false. 'Gris fonce tres mat' signifie une BaseColor "
			"gris fonce (R=G=B approximativement), Roughness elevee et Metallic faible, sans modifier des regions possedant leur propre override. "
			"RuntimeCapabilities decrit strictement ce que le runtime NullOn sait executer aujourd'hui. Unsupported ne rend jamais une intention "
			"World Director invalide : represente le monde demande avec les commandes existantes, mais ne pretends jamais que la capability est disponible en jeu. "
			"Les champs surfaceStrategy, gravityStrategy et spaceTransitionStrategy restent descriptifs et peuvent donc viser SphericalContinuous, Radial ou Continuous "
			"meme si SphericalTerrain, RadialGravity ou ContinuousLanding sont Unsupported. CurrentWorldMissingRuntimeCapabilities indique les ecarts deja presents. "
			"Ne retourne pas needs_clarification uniquement parce qu'une capability runtime manque ; utilise needs_clarification seulement si la cible ou l'intention elle-meme est ambigue. "
			"Si l'utilisateur demande d'executer maintenant une fonctionnalite de gameplay qui exige une capability Unsupported (par exemple atterrir reellement, decoller puis revenir en continu, ou obtenir une gravite radiale fonctionnelle), ne cree aucune WorldCommand et retourne status=unsupported_runtime_capability avec commands vide ; summary doit nommer clairement les capabilities manquantes. "
			"En revanche, si la demande consiste seulement a decrire/configurer un WorldState conceptuel utilisant une capability Unsupported, produis un plan ready normal et laisse World Director afficher le diagnostic runtime. "
			"Si la demande est hors du domaine de modification du monde World Director (par exemple ecrire un email), retourne status=out_of_domain avec commands vide et explique brievement pourquoi dans summary. N'invente jamais une WorldCommand pour repondre a une demande hors domaine. "
			"Le schema v6 ajoute mode=direct|build_plan et buildPlan={planId,goal,seed,phases}. Pour une demande locale/simple ou une modification conversationnelle normale, utilise mode=direct et buildPlan strictement vide (planId='', goal='', seed=0, phases=[]). Pour un gros prompt qui construit ou transforme un Environment avec au moins trois familles majeures parmi terrain/reliefs, Regions-Biomes-Surface, dressing, dressing local et geometrie non-heightfield, utilise mode=build_plan. Dans ce mode, commands contient toujours les WorldCommand normales et chaque commande est referencee exactement une fois par commandIndices dans une phase ; commandIndices utilise des indices zero-based dans le tableau commands (premiere commande = 0). Le Build Plan n'est jamais un second WorldState et ne contient aucune action Unreal libre. "
			"Un World Build Plan est ordonne et lisible. Utilise des phaseId stables et generiques tels que BaseTerrain, MajorRelief, RegionsSurface, NonHeightfieldGeometry, Dressing, LocalDressing seulement lorsque leur contenu est necessaire. order est strictement croissant. dependsOn ne reference que des phases precedentes. checkpointAfter=true pour toutes les phases non finales afin de permettre une reprise inter-session deterministe ; la phase finale peut egalement le laisser a true. Si aucun Environment Landscape approprie n'existe et que le gros prompt demande un monde terrestre complet, la premiere phase cree un Environment (par defaut 2000x2000 m pour une grande zone sans dimension explicite ; reserve les cartes plus grandes aux demandes explicites afin de garder une ebauche Editor raisonnable, profile=hills ou rolling selon l'intention). Les phases suivantes reutilisent exactement cet EnvironmentId. Pour un gros build global, tu peux choisir des positions coherentes dans le repere centre de l'Environment sans exiger SpatialContext : nord = y positif, sud = y negatif, centre proche de 0,0. Ces positions font partie du plan explicite et restent soumises a validation. "
			"Pour un gros prompt de vallee complete, decompose avec les primitives existantes : Environment/terrain de base, TerrainFeatures generiques pour reliefs, Regions+Biomes+MaterialFamily si necessaire, Geometry pour falaises/arches/surplombs, Dressing puis DressingOverride pour passages. N'invente jamais CreateCompleteWorld ni une commande Batch. Respecte la limite actuelle de 4 Regions Surface par Environment et les AssetIds de EnvironmentAssetCatalog. Les features lineaires d'un gros plan peuvent utiliser des environmentPath explicites coherents avec la mise en page generale ; les ancres viewport restent obligatoires uniquement pour les formulations locales du type d'ici jusque-la. Pour les TerrainFeatures Environment, respecte aussi les bornes du modele : depthMeters <= 128, heightMeters <= 256, falloff entre 0 et 1 et radiusMeters <= min(1000, demi-portee du terrain). Pour widthMeters, les cartes jusqu'a 2 km gardent un maximum de 1000 m ; sur une carte explicitement plus grande, la largeur peut monter jusqu'a la moitie de la plus petite dimension du terrain (par exemple 2000 m maximum sur 4 km x 4 km). N'agrandis pas une feature au-dela de ces limites : utilise sa position, son path ou plusieurs features coherentes si necessaire. "
			"Pour tous les statuts autres que ready, commands doit etre vide, mode=direct et buildPlan vide. Pour ready, commands doit contenir au moins une commande. "
			"Pour ModifyBody, ModifyTerrainFeature, ModifyRegion, ModifyBiome, ModifyMaterialFamily, ModifyEnvironmentDressing, ModifyEnvironmentDressingOverride et ModifyEnvironmentGeometry, chaque propriete de changes contient {isSet,value}; pour une TerrainFeature Environment, renseigne targetEnvironmentId et laisse targetSystemId/targetBodyId vides. compositionOrder est un patch absolu entier et doit rester isSet=false sauf demande explicite de reordonnancement. "
			"isSet=true uniquement pour ce qui est demande. Une proposition non appliquee n'existe pas dans le WorldState. ");

	if (bWorldInspectionMcpAvailable)
	{
		DeveloperInstructions += TEXT(
			"Les outils MCP World Director read-only get_world_summary, list_entities et get_entity peuvent etre utilises uniquement pour inspecter le WorldState courant. "
			"Lorsqu'une demande depend du nombre exact, de l'identite ou des proprietes d'entites existantes, utilise les outils World Director appropries plutot que de supposer l'etat du monde. "
			"Ces outils servent uniquement a l'observation. Toute modification du monde doit toujours etre exprimee exclusivement via les WorldCommand du schema de sortie existant puis passer par le pipeline World Director. "
			"Aucun outil MCP ne modifie Unreal ou le WorldState. N'utilise aucun autre outil, ne lis aucun fichier directement, n'accede pas a Unreal et n'execute rien.");
	}
	else
	{
		DeveloperInstructions += TEXT(
			"Le MCP World Director read-only n'est pas disponible pour cette session. N'utilise aucun outil, ne lis aucun fichier, n'accede pas a Unreal et n'execute rien.");
	}

	Params->SetStringField(TEXT("developerInstructions"), DeveloperInstructions);
	Params->SetStringField(TEXT("serviceName"), TEXT("nullon_world_director"));

	PendingRequestId = NextRequestId++;
	OutMessages.Add(MakeRequest(TEXT("thread/start"), Params, PendingRequestId));
	State = EState::WaitingThread;
}

void FWorldDirectorCodexProtocol::QueueTurnStart(TArray<FString>& OutMessages)
{
	const TSharedRef<FJsonObject> Input = MakeShared<FJsonObject>();
	Input->SetStringField(TEXT("type"), TEXT("text"));
	Input->SetStringField(
		TEXT("text"),
		FString::Printf(
			TEXT("%s\n\nDemande utilisateur :\n%s"),
			*PendingWorldContext,
			*PendingPrompt));

	const TSharedRef<FJsonObject> Params = MakeShared<FJsonObject>();
	Params->SetStringField(TEXT("threadId"), ThreadId);
	Params->SetArrayField(TEXT("input"), {MakeShared<FJsonValueObject>(Input)});
	Params->SetObjectField(TEXT("outputSchema"), BuildOutputSchema());

	PendingRequestId = NextRequestId++;
	OutMessages.Add(MakeRequest(TEXT("turn/start"), Params, PendingRequestId));
	State = EState::WaitingTurnStart;
}

bool FWorldDirectorCodexProtocol::CompleteFailure(
	EWorldDirectorAIResultCode Code,
	const FString& Diagnostic,
	FWorldDirectorAIResponse& OutCompletion,
	bool& bOutCompleted)
{
	OutCompletion = FWorldDirectorAIResponse::Failure(Code, Diagnostic);
	OutCompletion.ThreadId = ThreadId;
	OutCompletion.TurnId = TurnId;
	bOutCompleted = true;
	State = ThreadId.IsEmpty() ? EState::Disconnected : EState::Ready;
	PendingPrompt.Reset();
	PendingWorldContext.Reset();
	PendingRequestId = 0;
	return false;
}

bool FWorldDirectorCodexProtocol::ParseStructuredResponse(FWorldDirectorAIResponse& OutCompletion) const
{
	FString Error;
	FWorldDirectorAIResponse Parsed;
	if (!FWorldDirectorCommandProposalParser::Parse(FinalAgentMessage, Parsed, Error))
	{
		OutCompletion = FWorldDirectorAIResponse::Failure(
			EWorldDirectorAIResultCode::InvalidStructuredResponse,
			Error);
		OutCompletion.ThreadId = ThreadId;
		OutCompletion.TurnId = TurnId;
		return false;
	}

	Parsed.bSuccess = true;
	Parsed.Code = EWorldDirectorAIResultCode::Success;
	Parsed.ThreadId = ThreadId;
	Parsed.TurnId = TurnId;
	OutCompletion = MoveTemp(Parsed);
	return true;
}

bool FWorldDirectorCodexProtocol::IsAuthenticationError(const FString& Message)
{
	return Message.Contains(TEXT("auth"), ESearchCase::IgnoreCase)
		|| Message.Contains(TEXT("login"), ESearchCase::IgnoreCase)
		|| Message.Contains(TEXT("unauthorized"), ESearchCase::IgnoreCase)
		|| Message.Contains(TEXT("401"));
}

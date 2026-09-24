#if WITH_DEV_AUTOMATION_TESTS

#include "AI/WorldDirectorCodexProtocol.h"
#include "AI/WorldDirectorCommandProposalParser.h"
#include "Misc/AutomationTest.h"
#include "WorldDirectorModel.h"

namespace
{
	bool AdvanceToActiveTurn(
		FWorldDirectorCodexProtocol& Protocol,
		const FString& Prompt,
		const FString& ThreadId,
		const FString& TurnId,
		FWorldDirectorAIResponse& OutResult)
	{
		TArray<FString> Messages;
		const FWorldDirectorWorldDefinition EmptyWorld;
		if (!Protocol.BeginPrompt(Prompt, EmptyWorld, FWorldDirectorContextState(), Messages, OutResult) || Messages.Num() != 1)
		{
			return false;
		}

		bool bCompleted = false;
		Messages.Reset();
		if (!Protocol.HandleServerLine(TEXT("{\"id\":1,\"result\":{}}"), Messages, OutResult, bCompleted)
			|| bCompleted || Messages.Num() != 2)
		{
			return false;
		}

		Messages.Reset();
		const FString ThreadResponse = FString::Printf(
			TEXT("{\"id\":2,\"result\":{\"thread\":{\"id\":\"%s\"}}}"),
			*ThreadId);
		if (!Protocol.HandleServerLine(ThreadResponse, Messages, OutResult, bCompleted)
			|| bCompleted || Messages.Num() != 1)
		{
			return false;
		}

		Messages.Reset();
		const FString TurnResponse = FString::Printf(
			TEXT("{\"id\":3,\"result\":{\"turn\":{\"id\":\"%s\"}}}"),
			*TurnId);
		return Protocol.HandleServerLine(TurnResponse, Messages, OutResult, bCompleted)
			&& !bCompleted
			&& Protocol.IsBusy();
	}

	void CompleteTurn(
		FWorldDirectorCodexProtocol& Protocol,
		const FString& ThreadId,
		const FString& TurnId,
		const FString& AgentText,
		FWorldDirectorAIResponse& OutResult,
		bool& bOutCompleted)
	{
		TArray<FString> Messages;
		const FString EscapedText = AgentText.ReplaceCharWithEscapedChar();
		const FString Item = FString::Printf(
			TEXT("{\"method\":\"item/completed\",\"params\":{\"threadId\":\"%s\",\"turnId\":\"%s\",\"item\":{\"id\":\"item-1\",\"type\":\"agentMessage\",\"text\":\"%s\"}}}"),
			*ThreadId,
			*TurnId,
			*EscapedText);
		Protocol.HandleServerLine(Item, Messages, OutResult, bOutCompleted);

		const FString Completed = FString::Printf(
			TEXT("{\"method\":\"turn/completed\",\"params\":{\"threadId\":\"%s\",\"turn\":{\"id\":\"%s\",\"status\":\"completed\",\"items\":[]}}}"),
			*ThreadId,
			*TurnId);
		Protocol.HandleServerLine(Completed, Messages, OutResult, bOutCompleted);
	}
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FWorldDirectorCodexStructuredResponseTest,
	"NullOn.WorldDirector.Editor.Codex.StructuredResponse",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FWorldDirectorCodexStructuredResponseTest::RunTest(const FString& Parameters)
{
	{
		FWorldDirectorCodexProtocol SerializationProtocol;
		FWorldDirectorAIResponse SerializationResult;
		TArray<FString> SerializedMessages;
		TestTrue(
			TEXT("Requête initialize sérialisée"),
			SerializationProtocol.BeginPrompt(
				TEXT("Test JSONL"), FWorldDirectorWorldDefinition(), FWorldDirectorContextState(), SerializedMessages, SerializationResult));
		TestEqual(TEXT("Une requête initialize produite"), SerializedMessages.Num(), 1);
		if (SerializedMessages.Num() == 1)
		{
			TestFalse(TEXT("Le JSONL sortant ne contient aucun LF interne"), SerializedMessages[0].Contains(TEXT("\n")));
			TestFalse(TEXT("Le JSONL sortant ne contient aucun CR interne"), SerializedMessages[0].Contains(TEXT("\r")));
		}

		bool bCompleted = false;
		SerializedMessages.Reset();
		TestTrue(
			TEXT("La réponse initialize déclenche thread/start"),
			SerializationProtocol.HandleServerLine(
				TEXT("{\"id\":1,\"result\":{}}"),
				SerializedMessages,
				SerializationResult,
				bCompleted));
		TestEqual(TEXT("initialized et thread/start produits"), SerializedMessages.Num(), 2);
		if (SerializedMessages.Num() == 2)
		{
			const FString& ThreadStart = SerializedMessages[1];
			TestTrue(TEXT("Le cadrage World Director est envoyé"), ThreadStart.Contains(TEXT("World Director")));
			TestTrue(TEXT("Les commandes World Director sont cadrées"),
				ThreadStart.Contains(TEXT("CreateSystem"))
				&& ThreadStart.Contains(TEXT("CreateBody"))
				&& ThreadStart.Contains(TEXT("ModifyBody"))
				&& ThreadStart.Contains(TEXT("CreateEnvironment"))
				&& ThreadStart.Contains(TEXT("ModifyEnvironment"))
				&& ThreadStart.Contains(TEXT("CreateTerrainFeature"))
				&& ThreadStart.Contains(TEXT("ModifyTerrainFeature"))
				&& ThreadStart.Contains(TEXT("CreateRegion"))
				&& ThreadStart.Contains(TEXT("ModifyRegion"))
				&& ThreadStart.Contains(TEXT("CreateBiome"))
				&& ThreadStart.Contains(TEXT("ModifyBiome"))
				&& ThreadStart.Contains(TEXT("AssignBiomeToRegion")));
			TestTrue(TEXT("Une cible explicitement nommée reste une commande même si absente"),
				ThreadStart.Contains(TEXT("meme si cet ID n'existe pas")));
			TestTrue(TEXT("Un body existant impose son système et interdit un CreateSystem parasite"),
				ThreadStart.Contains(TEXT("son champ system= est autoritatif"))
				&& ThreadStart.Contains(TEXT("n'emets aucun CreateSystem"))
				&& ThreadStart.Contains(TEXT("body existant")));
			TestTrue(TEXT("La dernière feature est cadrée pour les références conversationnelles"),
				ThreadStart.Contains(TEXT("LastAffectedFeature")));
			TestTrue(TEXT("Le contexte spatial est la source imposée pour ici"),
				ThreadStart.Contains(TEXT("SpatialContext"))
				&& ThreadStart.Contains(TEXT("TargetPosition"))
				&& ThreadStart.Contains(TEXT("needs_clarification")));
			TestTrue(TEXT("L'accès à Unreal est explicitement exclu"), ThreadStart.Contains(TEXT("Unreal")));
			TestTrue(TEXT("Les capabilities runtime sont cadrées sans bloquer le WorldState"),
				ThreadStart.Contains(TEXT("RuntimeCapabilities"))
				&& ThreadStart.Contains(TEXT("Unsupported ne rend jamais"))
				&& ThreadStart.Contains(TEXT("ne pretends jamais que la capability est disponible")));
			TestTrue(TEXT("WD-019 cadre le langage naturel imparfait"),
				ThreadStart.Contains(TEXT("fautes de frappe"))
				&& ThreadStart.Contains(TEXT("abreviations"))
				&& ThreadStart.Contains(TEXT("formulations familieres")));
			TestTrue(TEXT("WD-019 interdit la résolution arbitraire des ambiguïtés"),
				ThreadStart.Contains(TEXT("vraie ambiguite"))
				&& ThreadStart.Contains(TEXT("status=needs_clarification")));
			TestTrue(TEXT("WD-019 exige un traitement explicite des contradictions"),
				ThreadStart.Contains(TEXT("demande contradictoire"))
				&& ThreadStart.Contains(TEXT("n'ignore silencieusement")));
			TestTrue(TEXT("WD-019 distingue capability runtime et hors domaine"),
				ThreadStart.Contains(TEXT("status=unsupported_runtime_capability"))
				&& ThreadStart.Contains(TEXT("status=out_of_domain"))
				&& ThreadStart.Contains(TEXT("ecrire un email")));
			TestFalse(TEXT("thread/start reste sur une seule ligne JSONL"), ThreadStart.Contains(TEXT("\n")) || ThreadStart.Contains(TEXT("\r")));
		}

		SerializedMessages.Reset();
		TestTrue(
			TEXT("La réponse thread/start déclenche turn/start"),
			SerializationProtocol.HandleServerLine(
				TEXT("{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-schema\"}}}"),
				SerializedMessages,
				SerializationResult,
				bCompleted));
		TestEqual(TEXT("Un turn/start produit"), SerializedMessages.Num(), 1);
		if (SerializedMessages.Num() == 1)
		{
			const FString& TurnStart = SerializedMessages[0];
			TestTrue(TEXT("Le schema v5 robuste est envoye"), TurnStart.Contains(TEXT("schemaVersion"))
				&& TurnStart.Contains(TEXT("status"))
				&& TurnStart.Contains(TEXT("needs_clarification"))
				&& TurnStart.Contains(TEXT("unsupported_runtime_capability"))
				&& TurnStart.Contains(TEXT("out_of_domain")));
			TestTrue(TEXT("Le tableau commands est imposé"), TurnStart.Contains(TEXT("commands")));
			TestFalse(TEXT("Le schema autorise commands vide pour clarification"), TurnStart.Contains(TEXT("minItems")));
			TestTrue(TEXT("Le patch ModifyBody est décrit"), TurnStart.Contains(TEXT("changes")));
			TestTrue(TEXT("Le schéma TerrainFeature est exposé"),
				TurnStart.Contains(TEXT("CreateTerrainFeature"))
				&& TurnStart.Contains(TEXT("ModifyTerrainFeature"))
				&& TurnStart.Contains(TEXT("MountainRange"))
				&& TurnStart.Contains(TEXT("sizeKm")));
			TestTrue(TEXT("Le schéma Environment terrain est exposé"),
				TurnStart.Contains(TEXT("CreateEnvironment"))
				&& TurnStart.Contains(TEXT("ModifyEnvironment"))
				&& TurnStart.Contains(TEXT("widthMeters"))
				&& TurnStart.Contains(TEXT("heightMeters"))
				&& TurnStart.Contains(TEXT("terrainProfile"))
				&& TurnStart.Contains(TEXT("rolling"))
				&& TurnStart.Contains(TEXT("hills"))
				&& TurnStart.Contains(TEXT("reliefAmplitudeMeters"))
				&& TurnStart.Contains(TEXT("roughness")));
			TestTrue(TEXT("Le schéma Region/Biome est exposé"),
				TurnStart.Contains(TEXT("CreateRegion"))
				&& TurnStart.Contains(TEXT("ModifyRegion"))
				&& TurnStart.Contains(TEXT("CreateBiome"))
				&& TurnStart.Contains(TEXT("ModifyBiome"))
				&& TurnStart.Contains(TEXT("AssignBiomeToRegion"))
				&& TurnStart.Contains(TEXT("vegetationLevel"))
				&& TurnStart.Contains(TEXT("rockiness")));
			TestTrue(TEXT("L'union supportée anyOf est utilisée"), TurnStart.Contains(TEXT("anyOf")));
			TestFalse(TEXT("L'union oneOf non supportée est absente"), TurnStart.Contains(TEXT("oneOf")));
			TestTrue(TEXT("La présence explicite isSet est imposée"), TurnStart.Contains(TEXT("isSet")));
			TestTrue(TEXT("Le contexte World Director vide est fourni"), TurnStart.Contains(TEXT("Current World Context")) && TurnStart.Contains(TEXT("Systems:")));
			TestFalse(TEXT("turn/start reste sur une seule ligne JSONL"), TurnStart.Contains(TEXT("\n")) || TurnStart.Contains(TEXT("\r")));
		}
	}

	FWorldDirectorCodexProtocol Protocol;
	FWorldDirectorAIResponse Result;
	TestTrue(
		TEXT("Handshake simulé jusqu'au turn actif"),
		AdvanceToActiveTurn(Protocol, TEXT("Crée une planète habitable"), TEXT("thread-1"), TEXT("turn-1"), Result));

	bool bCompleted = false;
	CompleteTurn(
		Protocol,
		TEXT("thread-1"),
		TEXT("turn-1"),
		TEXT("{\"schemaVersion\":5,\"status\":\"ready\",\"summary\":\"Créer un système.\",\"commands\":[{\"type\":\"CreateSystem\",\"payload\":{\"systemId\":\"System_001\",\"displayName\":\"Système\"}}]}"),
		Result,
		bCompleted);

	TestTrue(TEXT("Réponse terminée"), bCompleted);
	TestTrue(TEXT("Réponse structurée acceptée"), Result.bSuccess);
	TestEqual(TEXT("Version conservée"), Result.SchemaVersion, FWorldDirectorCommandProposalParser::CurrentSchemaVersion);
	TestEqual(TEXT("Statut ready conservé"), Result.ProposalStatus, EWorldDirectorAIProposalStatus::Ready);
	TestEqual(TEXT("Résumé conservé"), Result.Summary, FString(TEXT("Créer un système.")));
	TestEqual(TEXT("Commande convertie"), Result.Commands.Num(), 1);
	if (Result.Commands.Num() == 1)
	{
		TestEqual(TEXT("Type converti"), Result.Commands[0].Type, EWorldDirectorCommandType::CreateSystem);
		TestEqual(TEXT("ID converti"), Result.Commands[0].CreateSystem.SystemId.ToString(), FString(TEXT("System_001")));
	}
	TestEqual(TEXT("Thread corrélé"), Result.ThreadId, FString(TEXT("thread-1")));
	TestEqual(TEXT("Turn corrélé"), Result.TurnId, FString(TEXT("turn-1")));

	TArray<FString> SecondPromptMessages;
	TestTrue(
		TEXT("Deuxième prompt accepté dans la session"),
		Protocol.BeginPrompt(
			TEXT("Rends-la plus océanique"), FWorldDirectorWorldDefinition(), FWorldDirectorContextState(), SecondPromptMessages, Result));
	TestEqual(TEXT("Un seul turn/start est envoyé"), SecondPromptMessages.Num(), 1);
	if (SecondPromptMessages.Num() == 1)
	{
		TestTrue(TEXT("Le thread existant est réutilisé"), SecondPromptMessages[0].Contains(TEXT("thread-1")));
		TestTrue(TEXT("Le message est un turn/start"), SecondPromptMessages[0].Contains(TEXT("turn/start")));
		TestFalse(TEXT("Aucun second initialize"), SecondPromptMessages[0].Contains(TEXT("initialize")));
	}
	return true;
}


IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FWorldDirectorCodexContextBlockTest,
	"NullOn.WorldDirector.Editor.Codex.ContextBlock",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FWorldDirectorCodexContextBlockTest::RunTest(const FString& Parameters)
{
	FWorldDirectorWorldDefinition World;
	FWorldDirectorCelestialSystemDefinition System;
	System.PersistentId = FWorldDirectorPersistentId::FromString(TEXT("System_001"));
	System.DisplayName = TEXT("Système principal");

	FWorldDirectorCelestialBodyDefinition Planet;
	Planet.PersistentId = FWorldDirectorPersistentId::FromString(TEXT("Planet_001"));
	Planet.DisplayName = TEXT("Aurelia");
	Planet.SemanticType = EWorldDirectorCelestialBodySemanticType::Planet;
	Planet.RadiusKm = 6371.0;
	Planet.bHasAtmosphere = true;
	System.Bodies.Add(Planet);

	FWorldDirectorCelestialBodyDefinition Moon;
	Moon.PersistentId = FWorldDirectorPersistentId::FromString(TEXT("Moon_001"));
	Moon.DisplayName = TEXT("Veilleuse");
	Moon.SemanticType = EWorldDirectorCelestialBodySemanticType::Moon;
	Moon.RadiusKm = 900.0;
	Moon.bHasAtmosphere = false;
	Moon.SurfaceStrategy = EWorldDirectorSurfaceStrategy::SphericalContinuous;
	Moon.SpaceTransitionStrategy = EWorldDirectorSpaceTransitionStrategy::Continuous;
	Moon.GravityStrategy = EWorldDirectorGravityStrategy::Radial;
	Moon.ParentBodyId = Planet.PersistentId;
	FWorldDirectorTerrainFeatureDefinition Crater;
	Crater.PersistentId = FWorldDirectorPersistentId::FromString(TEXT("Crater_001"));
	Crater.DisplayName = TEXT("Cratère principal");
	Crater.BodyId = Moon.PersistentId;
	Crater.Type = EWorldDirectorTerrainFeatureType::Crater;
	Crater.Position.LatitudeDeg = 10.0;
	Crater.Position.LongitudeDeg = 20.0;
	Crater.SizeKm = 120.0;
	Crater.Intensity = 0.8;
	Moon.TerrainFeatures.Add(Crater);
	System.Bodies.Add(Moon);
	World.Systems.Add(System);

	FWorldDirectorEnvironmentDefinition Environment;
	Environment.PersistentId = FWorldDirectorPersistentId::FromString(TEXT("Environment_001"));
	Environment.DisplayName = TEXT("Terrain principal");
	Environment.Seed = 1234;
	Environment.bHasTerrain = true;
	Environment.Terrain = FWorldDirectorEnvironmentTerrainDefinition::MakeLandscape(
		2000.0,
		2000.0,
		EWorldDirectorEnvironmentTerrainProfile::Rolling,
		0.0,
		15.0,
		0.25);
	World.Environments.Add(Environment);

	FWorldDirectorContextState Context;
	Context.LastCreatedSystemId = System.PersistentId;
	Context.LastCreatedBodyId = Moon.PersistentId;
	Context.LastModifiedBodyId = Planet.PersistentId;
	Context.LastAffectedBodyId = Moon.PersistentId;
	Context.LastCreatedFeatureId = Crater.PersistentId;
	Context.LastModifiedFeatureId = Crater.PersistentId;
	Context.LastAffectedFeatureId = Crater.PersistentId;
	Context.SelectedBodyId = FWorldDirectorPersistentId::FromString(TEXT("Body_Missing"));

	const FString Block = FWorldDirectorCodexProtocol::BuildContextBlock(World, Context);
	TestTrue(TEXT("L'Environment procédural est listé"),
		Block.Contains(TEXT("Environment_001 - Terrain principal - seed=1234"))
		&& Block.Contains(TEXT("terrain=rolling"))
		&& Block.Contains(TEXT("amplitude=15.00m"))
		&& Block.Contains(TEXT("roughness=0.250")));
	TestTrue(TEXT("Le repère logique Environment est explicite"),
		Block.Contains(TEXT("logicalFrame=center=(0,0)m"))
		&& Block.Contains(TEXT("boundsX=[-1000.00,1000.00]m"))
		&& Block.Contains(TEXT("boundsY=[-1000.00,1000.00]m"))
		&& Block.Contains(TEXT("west(-X),east(+X)")));
	TestTrue(TEXT("Le système courant est listé"), Block.Contains(TEXT("System_001")));
	TestTrue(TEXT("La planète courante est listée"), Block.Contains(TEXT("Planet_001 - Planet")));
	TestTrue(TEXT("La lune courante est listée"), Block.Contains(TEXT("Moon_001 - Moon")));
	TestTrue(TEXT("Les propriétés utiles de la lune sont listées"),
		Block.Contains(TEXT("atmosphere=false")) && Block.Contains(TEXT("parent=Planet_001")));
	TestTrue(TEXT("Les stratégies runtime descriptives de la lune sont listées"),
		Block.Contains(TEXT("surface=SphericalContinuous"))
		&& Block.Contains(TEXT("transition=Continuous"))
		&& Block.Contains(TEXT("gravity=Radial"))
		&& Block.Contains(TEXT("runtimeRequirements=RadialGravity,SphericalTerrain,ContinuousLanding")));
	TestTrue(TEXT("Les capabilities NullOn actuelles sont transmises"),
		Block.Contains(TEXT("RuntimeCapabilities:"))
		&& Block.Contains(TEXT("RadialGravity=Unsupported"))
		&& Block.Contains(TEXT("SphericalTerrain=Unsupported"))
		&& Block.Contains(TEXT("RegionalTerrain=Unsupported"))
		&& Block.Contains(TEXT("AtmosphericTravel=Unsupported"))
		&& Block.Contains(TEXT("ContinuousLanding=Unsupported"))
		&& Block.Contains(TEXT("RuntimeTerrainModification=Unsupported")));
	TestTrue(TEXT("Les requirements manquants du monde sont transmis"),
		Block.Contains(TEXT("CurrentWorldMissingRuntimeCapabilities:"))
		&& Block.Contains(TEXT("SphericalTerrain - requiredBy=Moon_001"))
		&& Block.Contains(TEXT("RegionalTerrain - requiredBy=Planet_001"))
		&& Block.Contains(TEXT("AtmosphericTravel - requiredBy=Planet_001")));
	TestTrue(TEXT("LastCreatedBody est transmis"), Block.Contains(TEXT("LastCreatedBody: Moon_001")));
	TestTrue(TEXT("LastModifiedBody est transmis"), Block.Contains(TEXT("LastModifiedBody: Planet_001")));
	TestTrue(TEXT("LastAffectedBody est transmis"), Block.Contains(TEXT("LastAffectedBody: Moon_001")));
	TestTrue(TEXT("La feature courante est listée"),
		Block.Contains(TEXT("Crater_001 - Crater - body=Moon_001"))
		&& Block.Contains(TEXT("sizeKm=120")));
	TestTrue(TEXT("LastCreatedFeature est transmis"), Block.Contains(TEXT("LastCreatedFeature: Crater_001")));
	TestTrue(TEXT("LastModifiedFeature est transmis"), Block.Contains(TEXT("LastModifiedFeature: Crater_001")));
	TestTrue(TEXT("LastAffectedFeature est transmis"), Block.Contains(TEXT("LastAffectedFeature: Crater_001")));
	TestTrue(TEXT("Une sélection obsolète est normalisée"), Block.Contains(TEXT("SelectedBody: none")));
	TestTrue(TEXT("Contexte spatial vide explicitement transmis"),
		Block.Contains(TEXT("SpatialContext:"))
		&& Block.Contains(TEXT("TargetBody: none"))
		&& Block.Contains(TEXT("TargetPosition: none")));
	TestFalse(TEXT("L'historique transactionnel n'est pas envoyé"),
		Block.Contains(TEXT("Transaction"), ESearchCase::IgnoreCase)
		|| Block.Contains(TEXT("History"), ESearchCase::IgnoreCase));

	FWorldDirectorCodexProtocol Protocol;
	FWorldDirectorAIResponse Result;
	TArray<FString> Messages;
	TestTrue(TEXT("Prompt avec contexte accepté"), Protocol.BeginPrompt(TEXT("Elle doit être plus petite."), World, Context, Messages, Result));
	bool bCompleted = false;
	Messages.Reset();
	TestTrue(TEXT("Initialize traité"), Protocol.HandleServerLine(TEXT("{\"id\":1,\"result\":{}}"), Messages, Result, bCompleted));
	Messages.Reset();
	TestTrue(TEXT("Thread créé"), Protocol.HandleServerLine(
		TEXT("{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-context\"}}}"), Messages, Result, bCompleted));
	TestEqual(TEXT("Le contexte produit un turn/start"), Messages.Num(), 1);
	if (Messages.Num() == 1)
	{
		TestTrue(TEXT("Le WorldState est envoyé dans le turn"),
			Messages[0].Contains(TEXT("Planet_001")) && Messages[0].Contains(TEXT("Moon_001")));
		TestTrue(TEXT("L'Environment procédural est envoyé dans le turn"),
			Messages[0].Contains(TEXT("Environment_001")) && Messages[0].Contains(TEXT("terrain=rolling")));
		TestTrue(TEXT("Le contexte de référence est envoyé dans le turn"),
			Messages[0].Contains(TEXT("LastAffectedBody: Moon_001"))
			&& Messages[0].Contains(TEXT("LastAffectedFeature: Crater_001")));
		TestTrue(TEXT("La feature est envoyée dans le turn"), Messages[0].Contains(TEXT("Crater_001 - Crater")));
		TestTrue(TEXT("Les capabilities sont envoyées à chaque nouveau prompt"),
			Messages[0].Contains(TEXT("RuntimeCapabilities:"))
			&& Messages[0].Contains(TEXT("SphericalTerrain=Unsupported"))
			&& Messages[0].Contains(TEXT("CurrentWorldMissingRuntimeCapabilities:")));
	}
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FWorldDirectorCodexClarificationResponseTest,
	"NullOn.WorldDirector.Editor.Codex.ClarificationResponse",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FWorldDirectorCodexClarificationResponseTest::RunTest(const FString& Parameters)
{
	FWorldDirectorCodexProtocol Protocol;
	FWorldDirectorAIResponse Result;
	TestTrue(
		TEXT("Handshake simulé pour clarification"),
		AdvanceToActiveTurn(Protocol, TEXT("Rends la lune plus petite."), TEXT("thread-clarify"), TEXT("turn-clarify"), Result));

	bool bCompleted = false;
	CompleteTurn(
		Protocol,
		TEXT("thread-clarify"),
		TEXT("turn-clarify"),
		TEXT("{\"schemaVersion\":5,\"status\":\"needs_clarification\",\"summary\":\"Deux lunes existent. Laquelle veux-tu modifier ?\",\"commands\":[]}"),
		Result,
		bCompleted);

	TestTrue(TEXT("Clarification reçue comme réponse structurée"), bCompleted && Result.bSuccess);
	TestEqual(TEXT("Statut clarification conservé"), Result.ProposalStatus, EWorldDirectorAIProposalStatus::NeedsClarification);
	TestEqual(TEXT("Clarification ne contient aucune commande"), Result.Commands.Num(), 0);
	TestTrue(TEXT("Question de clarification conservée"), Result.Summary.Contains(TEXT("Laquelle")));
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FWorldDirectorCodexSemanticStatusResponseTest,
	"NullOn.WorldDirector.Editor.Codex.SemanticStatusResponses",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FWorldDirectorCodexSemanticStatusResponseTest::RunTest(const FString& Parameters)
{
	struct FCase
	{
		const TCHAR* Status;
		EWorldDirectorAIProposalStatus ProposalStatus;
		EWorldDirectorDiagnosticKind DiagnosticKind;
	};
	const FCase Cases[] = {
		{TEXT("unsupported_runtime_capability"), EWorldDirectorAIProposalStatus::UnsupportedRuntimeCapability, EWorldDirectorDiagnosticKind::UnsupportedRuntimeCapability},
		{TEXT("out_of_domain"), EWorldDirectorAIProposalStatus::OutOfDomain, EWorldDirectorDiagnosticKind::OutOfDomain}};

	for (const FCase& Case : Cases)
	{
		FWorldDirectorCodexProtocol Protocol;
		FWorldDirectorAIResponse Result;
		TestTrue(Case.Status, AdvanceToActiveTurn(Protocol, TEXT("Test statut"), TEXT("thread-status"), TEXT("turn-status"), Result));
		bool bCompleted = false;
		CompleteTurn(
			Protocol,
			TEXT("thread-status"),
			TEXT("turn-status"),
			FString::Printf(TEXT("{\"schemaVersion\":5,\"status\":\"%s\",\"summary\":\"Diagnostic WD-019.\",\"commands\":[]}"), Case.Status),
			Result,
			bCompleted);
		TestTrue(TEXT("Statut sémantique accepté"), bCompleted && Result.bSuccess);
		TestEqual(TEXT("ProposalStatus conservé"), Result.ProposalStatus, Case.ProposalStatus);
		TestEqual(TEXT("DiagnosticKind conservé"), Result.DiagnosticKind, Case.DiagnosticKind);
		TestEqual(TEXT("Aucune commande pour statut non-ready"), Result.Commands.Num(), 0);
	}
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FWorldDirectorCodexInvalidResponsesTest,
	"NullOn.WorldDirector.Editor.Codex.InvalidResponses",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FWorldDirectorCodexInvalidResponsesTest::RunTest(const FString& Parameters)
{
	const TArray<TPair<FString, FString>> Cases = {
		{TEXT("JSON invalide"), TEXT("pas du json")},
		{TEXT("Champ requis absent"), TEXT("{\"schemaVersion\":5,\"summary\":\"x\"}")},
		{TEXT("Plan vide"), TEXT("{\"schemaVersion\":5,\"status\":\"ready\",\"summary\":\"x\",\"commands\":[]}")},
		{TEXT("Version inconnue"), TEXT("{\"schemaVersion\":6,\"status\":\"ready\",\"summary\":\"x\",\"commands\":[]}")},
		{TEXT("Type inconnu"), TEXT("{\"schemaVersion\":5,\"status\":\"ready\",\"summary\":\"x\",\"commands\":[{\"type\":\"DeleteBody\",\"payload\":{}}]}")},
		{TEXT("Payload incomplet"), TEXT("{\"schemaVersion\":5,\"status\":\"ready\",\"summary\":\"x\",\"commands\":[{\"type\":\"CreateSystem\",\"payload\":{}}]}")}};

	for (const TPair<FString, FString>& Case : Cases)
	{
		FWorldDirectorCodexProtocol Protocol;
		FWorldDirectorAIResponse Result;
		TestTrue(*Case.Key, AdvanceToActiveTurn(Protocol, TEXT("Test"), TEXT("thread-1"), TEXT("turn-1"), Result));
		bool bCompleted = false;
		CompleteTurn(Protocol, TEXT("thread-1"), TEXT("turn-1"), Case.Value, Result, bCompleted);
		TestTrue(*FString::Printf(TEXT("%s : completion reçue"), *Case.Key), bCompleted);
		TestFalse(*FString::Printf(TEXT("%s : rejetée"), *Case.Key), Result.bSuccess);
		TestEqual(
			*FString::Printf(TEXT("%s : code explicite"), *Case.Key),
			Result.Code,
			EWorldDirectorAIResultCode::InvalidStructuredResponse);
		TestEqual(
			*FString::Printf(TEXT("%s : diagnostic InvalidModelResponse"), *Case.Key),
			Result.DiagnosticKind,
			EWorldDirectorDiagnosticKind::InvalidModelResponse);
	}
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FWorldDirectorCodexMcpInstructionsTest,
	"NullOn.WorldDirector.Editor.Codex.MCP.ReadOnlyInstructions",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FWorldDirectorCodexMcpInstructionsTest::RunTest(const FString& Parameters)
{
	auto BuildThreadStart = [this](bool bMcpAvailable, FString& OutThreadStart) -> bool
	{
		FWorldDirectorCodexProtocol Protocol;
		Protocol.SetWorldInspectionMcpAvailable(bMcpAvailable);
		FWorldDirectorAIResponse Result;
		TArray<FString> Messages;
		if (!Protocol.BeginPrompt(
			TEXT("Inspecte le monde."),
			FWorldDirectorWorldDefinition(),
			FWorldDirectorContextState(),
			Messages,
			Result))
		{
			return false;
		}

		bool bCompleted = false;
		Messages.Reset();
		if (!Protocol.HandleServerLine(TEXT("{\"id\":1,\"result\":{}}"), Messages, Result, bCompleted)
			|| bCompleted
			|| Messages.Num() != 2)
		{
			return false;
		}

		OutThreadStart = Messages[1];
		return true;
	};

	FString WithMcp;
	if (TestTrue(TEXT("thread/start construit avec MCP"), BuildThreadStart(true, WithMcp)))
	{
		TestTrue(TEXT("get_world_summary autorisé"), WithMcp.Contains(TEXT("get_world_summary")));
		TestTrue(TEXT("list_entities autorisé"), WithMcp.Contains(TEXT("list_entities")));
		TestTrue(TEXT("get_entity autorisé"), WithMcp.Contains(TEXT("get_entity")));
		TestTrue(TEXT("MCP reste observation uniquement"), WithMcp.Contains(TEXT("uniquement a l'observation")));
		TestTrue(TEXT("Les modifications restent WorldCommand"), WithMcp.Contains(TEXT("exclusivement via les WorldCommand")));
		TestTrue(TEXT("Les autres outils restent interdits"), WithMcp.Contains(TEXT("N'utilise aucun autre outil")));
		TestTrue(TEXT("Disposition globale de géométrie sans clic autorisée"), WithMcp.Contains(TEXT("n'exige PAS TargetEnvironmentPosition")));
		TestTrue(TEXT("Zéro falaise crée une paire"), WithMcp.Contains(TEXT("zero falaise + 'une falaise de chaque cote' signifie creer deux falaises")));
		TestTrue(TEXT("Fallback spatial Environment déterministe"), WithMcp.Contains(TEXT("x=-0.30*requestedWidthMeters")));
		TestTrue(TEXT("Dimensions par défaut sans clarification"), WithMcp.Contains(TEXT("widthMeters=600, depthMeters=80, heightMeters=120")));
		TestTrue(TEXT("IDs de paire déterministes"), WithMcp.Contains(TEXT("Geometry_001 puis Geometry_002")));
	}

	FString WithoutMcp;
	if (TestTrue(TEXT("thread/start construit sans MCP"), BuildThreadStart(false, WithoutMcp)))
	{
		TestTrue(TEXT("Indisponibilité MCP explicite"), WithoutMcp.Contains(TEXT("MCP World Director read-only n'est pas disponible")));
		TestTrue(TEXT("Aucun outil autorisé sans MCP"), WithoutMcp.Contains(TEXT("N'utilise aucun outil")));
	}
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FWorldDirectorCodexFailuresTest,
	"NullOn.WorldDirector.Editor.Codex.Failures",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FWorldDirectorCodexFailuresTest::RunTest(const FString& Parameters)
{
	{
		FWorldDirectorCodexProtocol Protocol;
		TArray<FString> Messages;
		FWorldDirectorAIResponse Result;
		TestTrue(TEXT("Requête initiale créée"), Protocol.BeginPrompt(
			TEXT("Test"), FWorldDirectorWorldDefinition(), FWorldDirectorContextState(), Messages, Result));
		bool bCompleted = false;
		Messages.Reset();
		Protocol.HandleServerLine(
			TEXT("{\"id\":1,\"error\":{\"code\":401,\"message\":\"Unauthorized: authentication required\"}}"),
			Messages,
			Result,
			bCompleted);
		TestTrue(TEXT("Erreur App Server termine la requête"), bCompleted);
		TestEqual(TEXT("Authentification reconnue"), Result.Code, EWorldDirectorAIResultCode::AuthenticationRequired);
	}

	{
		FWorldDirectorCodexProtocol Protocol;
		TArray<FString> Messages;
		FWorldDirectorAIResponse Result;
		TestTrue(TEXT("Requête pour arrêt process créée"), Protocol.BeginPrompt(
			TEXT("Test"), FWorldDirectorWorldDefinition(), FWorldDirectorContextState(), Messages, Result));
		Protocol.HandleTransportFailure(
			EWorldDirectorAIResultCode::ProcessStopped,
			TEXT("Processus interrompu"),
			Result);
		TestFalse(TEXT("Arrêt inattendu échoue proprement"), Result.bSuccess);
		TestEqual(TEXT("Code arrêt process"), Result.Code, EWorldDirectorAIResultCode::ProcessStopped);
		TestFalse(TEXT("Protocole réinitialisé"), Protocol.IsBusy());
	}
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FWorldDirectorCodexCorrelationAndPurityTest,
	"NullOn.WorldDirector.Editor.Codex.CorrelationAndPurity",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FWorldDirectorCodexCorrelationAndPurityTest::RunTest(const FString& Parameters)
{
	FWorldDirectorWorldDefinition World;
	FWorldDirectorCelestialSystemDefinition System;
	System.PersistentId = FWorldDirectorPersistentId::FromString(TEXT("System_001"));
	System.DisplayName = TEXT("Système intact");
	World.AddSystem(System);
	const int32 SystemCountBefore = World.Systems.Num();
	const FString DisplayNameBefore = World.Systems[0].DisplayName;

	FWorldDirectorCodexProtocol RequestProtocol;
	FWorldDirectorAIResponse Result;
	TArray<FString> InitialMessages;
	TestTrue(TEXT("Requête de corrélation créée"), RequestProtocol.BeginPrompt(TEXT("Test"), World, FWorldDirectorContextState(), InitialMessages, Result));
	InitialMessages.Reset();
	bool bWrongRequestCompleted = false;
	RequestProtocol.HandleServerLine(
		TEXT("{\"id\":999,\"result\":{\"thread\":{\"id\":\"thread-wrong\"}}}"),
		InitialMessages,
		Result,
		bWrongRequestCompleted);
	TestFalse(TEXT("Réponse d'un autre request ignorée"), bWrongRequestCompleted);
	TestTrue(TEXT("Request attendu toujours actif"), RequestProtocol.IsBusy());
	TestEqual(TEXT("Aucun message produit pour le mauvais request"), InitialMessages.Num(), 0);

	FWorldDirectorCodexProtocol Protocol;
	TestTrue(TEXT("Turn actif"), AdvanceToActiveTurn(Protocol, TEXT("Test"), TEXT("thread-good"), TEXT("turn-good"), Result));

	TArray<FString> Messages;
	bool bCompleted = false;
	Protocol.HandleServerLine(
		TEXT("{\"method\":\"item/completed\",\"params\":{\"threadId\":\"thread-other\",\"turnId\":\"turn-other\",\"item\":{\"id\":\"wrong\",\"type\":\"agentMessage\",\"text\":\"wrong\"}}}"),
		Messages,
		Result,
		bCompleted);
	Protocol.HandleServerLine(
		TEXT("{\"method\":\"turn/completed\",\"params\":{\"threadId\":\"thread-other\",\"turn\":{\"id\":\"turn-other\",\"status\":\"completed\",\"items\":[]}}}"),
		Messages,
		Result,
		bCompleted);
	TestFalse(TEXT("Notification d'un autre turn ignorée"), bCompleted);
	TestTrue(TEXT("Requête attend toujours son turn"), Protocol.IsBusy());

	CompleteTurn(
		Protocol,
		TEXT("thread-good"),
		TEXT("turn-good"),
		TEXT("{\"schemaVersion\":5,\"status\":\"ready\",\"summary\":\"Aucune mutation.\",\"commands\":[{\"type\":\"ModifyBody\",\"payload\":{")
		TEXT("\"targetSystemId\":\"System_001\",\"targetBodyId\":\"Planet_999\",\"changes\":{")
		TEXT("\"displayName\":{\"isSet\":false,\"value\":\"\"},\"semanticType\":{\"isSet\":false,\"value\":\"Planet\"},")
		TEXT("\"radiusKm\":{\"isSet\":false,\"value\":0},\"hasAtmosphere\":{\"isSet\":true,\"value\":false},")
		TEXT("\"surfaceStrategy\":{\"isSet\":false,\"value\":\"Regional\"},\"spaceTransitionStrategy\":{\"isSet\":false,\"value\":\"AtmosphericLoading\"},")
		TEXT("\"gravityStrategy\":{\"isSet\":false,\"value\":\"Standard\"},\"surfaceGravity\":{\"isSet\":false,\"value\":0},")
		TEXT("\"parentBodyId\":{\"isSet\":false,\"value\":null}}}}]}"),
		Result,
		bCompleted);
	TestTrue(TEXT("Bon turn accepté"), Result.bSuccess);
	TestEqual(TEXT("Commande du bon turn"), Result.Commands.Num(), 1);
	TestEqual(TEXT("Nombre de systèmes inchangé"), World.Systems.Num(), SystemCountBefore);
	TestEqual(TEXT("Données métier inchangées"), World.Systems[0].DisplayName, DisplayNameBefore);
	return true;
}

#endif

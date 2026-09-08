.pragma library

var strings = {
    "Antigravity Usage":
        { fr: "Utilisation Antigravity" },
    "Account":
        { fr: "Compte" },
    "Weekly Limit":
        { fr: "Limite hebdomadaire" },
    "Five Hour Limit":
        { fr: "Limite 5 heures" },
    "used":
        { fr: "utilisé" },
    "left":
        { fr: "restant" },
    "Resets in":
        { fr: "Réinitialise dans" },
    "Resetting...":
        { fr: "Réinitialisation..." },
    "Not signed in":
        { fr: "Non connecté" },
    "Run agy and sign in with Google to see your usage.":
        { fr: "Lancez agy et connectez-vous avec Google pour voir votre utilisation." },
    "Loading...":
        { fr: "Chargement..." },
    // Settings
    "Monitor your Google Antigravity (agy) usage. The 5-hour and weekly limits are read from the same Cloud Code backend the agy CLI uses.":
        { fr: "Surveillez l'utilisation de Google Antigravity (agy). Les limites 5 heures et hebdomadaires proviennent du même backend Cloud Code que le CLI agy." },
    "Refresh Interval":
        { fr: "Intervalle de rafraîchissement" },
    "How often to fetch usage data (minutes)":
        { fr: "Fréquence de mise à jour des données (minutes)" },
    "Show Antigravity icon":
        { fr: "Afficher l'icône Antigravity" },
    "Show the Antigravity logo in the taskbar pill":
        { fr: "Afficher le logo Antigravity dans la pastille de la barre des tâches" },
    "Tint icon with accent color":
        { fr: "Teinter l'icône avec la couleur d'accent" },
    "Use the DMS accent color for the icon instead of the Antigravity blue":
        { fr: "Utiliser la couleur d'accent DMS pour l'icône au lieu du bleu Antigravity" },
}

function tr(key, lang) {
    if (!lang || lang === "en" || !strings[key] || !strings[key][lang])
        return key
    return strings[key][lang]
}

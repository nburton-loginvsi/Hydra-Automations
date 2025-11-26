# Hydra-Automations
Scripts and automations helpful in Hydra deployments  

---

**SessionConsolidationHelper.ps1**

NOTE THAT THIS FUNCTIONALITY HAS BEEN BUILT INTO HYDRA 2.0!

See here for details: https://docs.loginvsi.com/hydra/2.0.0/autoscaling#id-(2.0.0)Autoscaling-SessionConsolidation

This script is handy in conjunction with Hydra's Session Consolidation feature. Because Hydra only sends messages during the consolidation process, it's possible that users just ignore the message and don't logoff like we nicely ask them to. This helper can be used as a scheduled script at the beginning of the consolidation process (when the last schedule ends) to forcefully logoff users after X amount of time to help move the consolidation process quicker and save on Azure spend.   

The AVD messaging process logs an event to the RemoteDesktopServices Event Log. It shows the exact header and body of the message, so this script runs for X amount of time in the background under SYSTEM. If it sees the content in the SearchTerms variable, it triggers a logoff for all users in X amount of seconds.  

---

**SelfDeleteADObjectWithBind.ps1**  

Hydra has a built-in script to automatically delete the Entra object of an account, but NOT the on-prem AD object. Although the default password reset/sync route is preferrable for AD deployments, this script can be handy for deleting all session hosts in a pool for a mass renames or deletions, for example. This uses the Hydra_ServiceAccount_PSC PSCredential object, so ensure that a service account is properly defined for the host pool, the script has the service account option enabled, and the account has access to delete AD computer accounts.  

---

**ConvertHostPoolForTesting.ps1**   

This script can convert an AVD Host Pool (or really any device) to an automated testing host for use with Login Enterprise. This is useful to combine with Hydra's capability of running scripts at deployment time within the New Session Hosts tab. Simply set the $applianceFQDN variable to your LE appliance FQDN. The script will download the EXE and automatically place the shortcut in the ALLUSERSPROFILE startup directory. 

---

**AppScripts directory**

Non-Hydra-specific app scripts that can be used by Hydra's scripting engine for deployment/imaging automations, such as setting the fallback mechanism for Zoom. 


#Please see 
#  http://soerennielsen.wordpress.com/2010/12/23/automatic-fix-of-pre-upgrade-issues-sharepoint-2007-to-2010/
#
# for full details.
#
# 23/12-2010 Søren L Nielsen


#references
[void][reflection.assembly]::LoadWithPartialName("Microsoft.SharePoint")
[void][reflection.assembly]::LoadWithPartialName("Microsoft.SharePoint.Administration")

#Options
#----------

$verboseLevel = 3 # 3 max, 0 errors only, -1 nothing
	#3 very verbose
	#2 Info
    #1 warning (yellow)
    #0 Error (red)

#Should we apply changes or only perform "whatif" like operation? 
# It will all changes and also highlight most security problems
$whatIf = $true
	
#Limit to one particular database?
# note: Only DB name used as switch not server 
# Before you trust the script you may want to test it on only one db
$targetdb = ""



function FixUpdateIssues() {

    Log 2 "Retrieving site structure"
    
    $allwebsxml = [xml](stsadm -o enumallwebs -includewebparts -includefeatures -includesetupfiles)

    #Orphaned sites
	RemoveOrphanedSites $allwebsxml 

	#Activated web scoped features that have since been removed
	RemoveInvalidWebFeatures $allwebsxml 

    #Activated site col features that have since been removed
	RemoveInvalidSiteCollectionFeatures $allwebsxml 

	#Webparts with fatal errors (presumably because they are no longer deployed)
    RemoveInvalidWebparts $allwebsxml 

    #Remove missing setup files
    RemoveMissingSetupFiles $allwebsxml 
    
}

# Deactivates all features that are activated at web level but have since been uninstalled
# i.e. there is no longe any feature definition for those.
#
# By Søren Nielsen
function RemoveInvalidWebFeatures( $allwebsxml ){
	#Run through all the webs that and remove the missing features that may be activated there

	Log 2 "Removing activated uninstalled features" 
	
	if( ![string]::IsNullOrEmpty( $targetdb ) ){
		$webs = $allwebsxml.SelectNodes("/Databases/Database[@Name='$targetdb']/Site[@InSiteMap='True']/Webs/Web" )
	}
	else{
		$webs = $allwebsxml.SelectNodes("/Databases/Database/Site[@InSiteMap='True']/Webs/Web" )
	}

	foreach( $web in $webs ){
	
		&{
			$featuresMissing = $web.SelectNodes("Features/Feature[@Status='Missing']")

			if( $featuresMissing.Count -gt 0){
			
				$siteid = [Guid] $web.ParentNode.ParentNode.id
				$webid = [Guid]$web.id

				$site = new-object Microsoft.SharePoint.SPSite( $siteid )
				$spweb = $site.OpenWeb( $webid )
				
				foreach( $feature in $featuresMissing ){
					#remove with force (required for missings)
					Log 1 ("Removing feature " + $feature.id + " at web " + $site.url + $web.url)
					if( !$whatIf  ){
						$spweb.Features.Remove( $feature.Id, $true ) 
					}
				}					
				
				if( $spweb ){
					$spweb.Dispose()
				}
				if( $site ){
					$site.Dispose()                        
				}
				
				trap {
    				Log 0 ("RemoveInvalidWebFeatures: Error (Exception :" + $_.Exception.ToString() + ")"); 
					continue
				}
			}
		}	
	}
}


# Deactivates all features that are activated at site collection level but have since been uninstalled
# i.e. there is no longe any feature definition for those.
#
# This version crawls the entire site structure as it is not reported by enumallwebs
#
# By Søren Nielsen
function RemoveInvalidSiteCollectionFeatures( $allwebsxml ){

	Log 2 "Removing site collection level activated uninstalled features" 
	
	if( ![string]::IsNullOrEmpty( $targetdb ) ){
		$sites = $allwebsxml.SelectNodes("/Databases/Database[@Name='$targetdb']/Site[@InSiteMap='True']" )
	}
	else{
		$sites = $allwebsxml.SelectNodes("/Databases/Database/Site[@InSiteMap='True']" )
	}


	foreach( $sitexml in $sites ){			
        &{
            $siteid = [Guid]$sitexml.id
            $site = new-object Microsoft.SharePoint.SPSite( $siteid )
			
            Log 3 ("Checking site " + $site.url + " for uninstalled activated features" )

            #Go through the features at site collection level
            
            foreach( $feature in $site.Features ) {
                if( !$feature.Definition ){
                    #Feature with no definition = uninstalled feature (though still activated)
					Log 1 ("Removing uninstalled activated feature " + $feature.DefinitionId + " at site " + $site.url )
					if( !$whatIf  ){
						$site.Features.Remove( $feature.DefinitionId, $true ) 
					}
                    
                }
            }

            if( $site ){
    		  $site.Dispose()                        
            }
            
            trap {
        		Log 0 ("RemoveInvalidSiteCollectionFeatures: Error (Exception :" + $_.Exception.ToString() + ")"); 
    			continue
    		}
		}	
	}
}


# Remove files 
#
#
function RemoveMissingSetupFiles( $allwebsxml ){
	#Run through all the webs that and remove the missing features that may be activated there

	Log 2 "Removing missing setup files" 
	
	if( ![string]::IsNullOrEmpty( $targetdb ) ){
		$webs = $allwebsxml.SelectNodes("/Databases/Database[@Name='$targetdb']/Site[@InSiteMap='True']/Webs/Web" )
	}
	else{
		$webs = $allwebsxml.SelectNodes("/Databases/Database/Site[@InSiteMap='True']/Webs/Web" )
	}

	foreach( $web in $webs ){
	
		&{
			$filesMissing = $web.SelectNodes("SetupFiles/SetupFile[@Status='Missing']")

			if( $filesMissing.Count -gt 0){
			
				$siteid = [Guid] $web.ParentNode.ParentNode.id
				$webid = [Guid]$web.id
				
                $site = new-object Microsoft.SharePoint.SPSite( $siteid )
				$spweb = $site.OpenWeb( $webid )

                #Gather files to delete from xml
                $fileList = ""
				foreach( $file in $filesMissing ){
                    
					Log 3 ("File to remove " + $file.Path + " at web " + $site.url + $web.url)
                    if( $fileList.length -gt 0 ){
                        $fileList += ","
                    }
                    #Strip the absolute part of path    
					$fileList += "'" + $file.Path.Substring( $file.Path.IndexOf("Features") ).replace("'", "''") + "'"
				}	
                
                Log 3 ("Files to remove from web: $fileList") 				
				
                
                #execute some SQL to get at the sharepoint paths
                #-----------------------------------------------
                
        		#setup the SQL connection
                $db = $web.parentNode.parentNode.parentNode                
        		$SqlConn = New-Object System.Data.SqlClient.SqlConnection                
        		$SqlConn.ConnectionString = "Server=" + $db.DataSource + "; Database=" + $db.Name + "; Integrated Security = True"
        		$sql = "SELECT     Id, SiteId, webId, ListId, DirName, LeafName " +
                       "FROM       AllDocs " +
                       "WHERE     SetupPath in ($fileList) and webId='$webid' "
                                
        		$SqlCmd = New-Object System.Data.SqlClient.SqlCommand
        		$SqlCmd.Connection = $SqlConn
        		$SqlCmd.CommandText = $sql
        		$SqlAdapter = New-Object System.Data.SqlClient.SqlDataAdapter
        		$SqlAdapter.SelectCommand = $SqlCmd
        		$DataSet = New-Object System.Data.DataSet
        		$null = $SqlAdapter.Fill($DataSet) #suppress output



                #TODO: Compare counts
        		foreach( $row in $DataSet.Tables[0] ){
        			
                    &{
                        $file = $spweb.GetFile([Guid]$row["Id"])
                        
                        if ($file.InDocumentLibrary -and $file.Item) {
                            if ( IsCheckedOut($file) -and !IsCheckedOutByCurrentUser($file)) {
                    		
                    			$fileid = [Guid]$file.UniqueId
                    			Log 1 ("File checked out by other user, overriding checkout")
                    			if( !$whatIf  ){
                    				PublishListItem $file.Item $file.Item.ParentList "Override checkout to fix missing setup files"
                    			}
                    			#re-get file to work on it
                    			$file = $spweb.GetFile( $fileid )		
                            } 
                            else {
                                if ( $file.MinorVersion -gt 0 ){
                                     #publish a major version to clear old drafts
                    		  	     Log 1 ("File with minor version, publishing major")
                    			     if( !$whatIf  ){
                    				    PublishListItem $file.Item $file.Item.ParentList "Override checkout to fix missing setup files"
                    			     }
                    			     #re-get file to work on it
                    			     $file = $spweb.GetFile( $fileid )		
                                 }
                            }
                        }
                        
                        Log 1 ("Deleting file " + $spweb.url + "/" + [string]$row["DirName"] + "/" + [string]$row["LeafName"] )
                        if(!$whatIf){
                            $file.Delete()
                        }
        				trap {
            				Log 0 ("RemoveMissingSetupFiles: Failed to remove file (Exception :" + $_.Exception.ToString() + ")"); 
        					continue
        				}
                    }
                    
                }

                
				if( $spweb ){
					$spweb.Dispose()
				}
				if( $site ){
					$site.Dispose()                        
				}
				
				trap {
    				Log 0 ("RemoveMissingSetupFiles: Error (Exception :" + $_.Exception.ToString() + ")"); 
					continue
				}
			}
		}	
	}
}



# Remove all orphan sites by calling STSadm -o deletesite with force param. 
#
# Repair database operation does not always fix the orphaned sites, deletesite do.
#
# By Søren Nielsen
function RemoveOrphanedSites( $allwebsxml ){
		
	Log 2 "Removing orphan sites" 
	

	if( ![string]::IsNullOrEmpty( $targetdb ) ){
		$sites = $allwebsxml.SelectNodes("/Databases/Database[@Name='$targetdb']/Site[@InSiteMap='False']" )
	}
	else{
		$sites = $allwebsxml.SelectNodes("/Databases/Database/Site[@InSiteMap='False']" )
	}


	foreach( $site in $sites ){			
		$siteid = $site.id
		$dbserver = $site.ParentNode.DataSource
		$dbname = $site.ParentNode.Name

		Log 1 ("Deleting orphan site " + $siteid + " in database " + $dbname)
		if( !$whatIf  ){
			stsadm -o deletesite -force -siteid $siteid -databasename $dbname -databaseserver $dbserver 
		}
	}
	
	trap {
		Log 0 ("RemoveOrphanedSites: Error (Exception :" + $_.Exception.ToString() + ")"); 
		continue
	}
}

# Attempt to remove all invalid webparts from the farm (subject to global options)
#
# Goes through every database that contain webparts marked as "missing" from stsadm -o enumallwebs.
#
# Uses direct SQL towards database to identify the pages that contain missing webparts - there don't seem to be 
# any other way to identify these pages as some of them might not be deployed to the farm anymore but their presence
# in the form of configured webparts may still be there. 
#
# Proper API is used for removing the webparts.
# 
# By Søren Nielsen
function RemoveInvalidWebparts([xml]$allwebsxml) {
    
    Log 2 "Removing Invalid Webparts"

    $count = 0
	
	#missing webparts
    
	if( ![string]::IsNullOrEmpty( $targetdb ) ){
		$dbs = $allwebsxml.SelectNodes("/Databases/Database[@Name='$targetdb']" );
	}
	else{
		$dbs = $allwebsxml.SelectNodes("/Databases/Database" );
	}
	
	foreach( $db in $dbs ) {
		#Find the missing webparts in the DB
		Log 3 ("Checking for missing webparts in " + $db.DataSource + "\\" + $db.Name)
		
		#Get list of all missing webparts within DB
		$wps = $db.SelectNodes("Site[@InSiteMap='True']/Webs/Web/WebParts/WebPart[@Status='Missing']" )
		$wpSet = $null
		foreach( $wp in $wps ){			
			if( $wpSet ){
				$wpSet += ","
			}
			$wpSet = [String]::Concat($wpSet, "'", $wp.Id, "'")
		}
		
		if( !$wpSet ){
			Log 3 ("No missing webparts in " + $db.Name)
			continue;
		}

		#setup the SQL connection
		$SqlConn = New-Object System.Data.SqlClient.SqlConnection
		$SqlConn.ConnectionString = "Server=" + $db.DataSource + "; Database=" + $db.Name + "; Integrated Security = True"

		
		#Retrieve list of webpart instance id from the type ids in the xml datasource
		#Why? Because some webparts with "bad markup" will not show as having the "FatalError" property set, but they are still 
		# fatally ill.
		$sqlWebParts = "SELECT     tp_SiteId, tp_ID, tp_PageUrlID " +
						"FROM         WebParts " +
						"WHERE     tp_WebPartTypeId IN ($wpSet)"
		$SqlCmd = New-Object System.Data.SqlClient.SqlCommand
		$SqlCmd.Connection = $SqlConn
		$SqlCmd.CommandText = $sqlWebParts
		$SqlAdapter = New-Object System.Data.SqlClient.SqlDataAdapter
		$SqlAdapter.SelectCommand = $SqlCmd
		$DataSet = New-Object System.Data.DataSet
		$null = $SqlAdapter.Fill($DataSet) #suppress output

		#Build a hashtable for errored webpart instance id's
		$errorWebPartIds = @{}
		foreach( $row in $DataSet.Tables[0] ){
			$id = [Guid]$row["tp_ID"]
			Log 3 "Adding instance id '$id' to error list"
            if( !$errorWebPartIds.ContainsKey( $id ) ){
			 $errorWebPartIds.Add( $id, $true )
            }
		}		
		#Note: Might want to compare counts here in the future
		
				
		#retrieve list of files from db. 
		#Need to retrieve "site id, web id, file id" (ordered by that order)
		$SqlQuery = "select distinct ad.siteid, ad.webid, ad.id as fileid " + 
					"from dbo.WebParts wp join dbo.AllDocs ad on wp.tp_PageUrlID = ad.Id " + 
					"where wp.tp_WebPartTypeId in ($wpSet) " +
					"order by ad.siteid, ad.webid"
	
		$SqlCmd = New-Object System.Data.SqlClient.SqlCommand
		$SqlCmd.Connection = $SqlConn
		$SqlCmd.CommandText = $SqlQuery
		$SqlAdapter = New-Object System.Data.SqlClient.SqlDataAdapter
		$SqlAdapter.SelectCommand = $SqlCmd
		$DataSet = New-Object System.Data.DataSet
		$null = $SqlAdapter.Fill($DataSet) #suppress output
		$SqlConn.Close()
		
		$siteid = $null
		$webid = $null
		$site = $null
		$web = $null		
		
		#Go through each site and web in the dataset
		foreach( $row in $DataSet.Tables[0] ){
			#If this is a new site, close old one and open new
			if( [Guid]$row["siteid"] -ne $siteid ){
				if( $site ){
					$site.Dispose()
				}
				
				$siteid = [Guid]$row["siteid"]				
				$site = new-object Microsoft.SharePoint.SPSite( $siteid )
			}
			
			#If this is a new site, close old one and open new
			if( [Guid]$row["webid"] -ne $webid ){
				if( $web ){
					$web.Dispose()
				}
				
				$webid = [Guid]$row["webid"]				
				$web = $site.OpenWeb( $webid )
			}
			
			$fileid = [Guid]$row["fileid"]
			$file = $web.GetFile( $fileid )
			
			&{
				CheckAndRemoveMissingWebpartsFromFile $web $file $errorWebPartIds		
				
				trap {
    				Log 0 ("RemoveInvalidWebparts: Error removing webparts from '" + $web.Url + "/" + $file.Url + "' (Exception :" + $_.Exception.ToString()); 
					continue
				}
			}	 						
		}


		if( $web ){
            $web.Dispose()
        }
        if( $site ){
            $site.Dispose()                        
        }
	}	
}

# Remove invalid webparts from a given file (SPFile)
# Invalid webparts are those with fatal errors, i.e. not working or not deployed
#
# By Søren Nielsen
function CheckAndRemoveMissingWebpartsFromFile($web, $file, $errorWebPartIds){	
	if (!$file)
    {
        return
    }
#    elseif( !$file.Url.ToLowerInvariant().EndsWith(".aspx")){
#		Log 1 ("Unable to remove webpart from " + $web.Url + "/" + $file.Url)
#        return
#    }
    
	Log 2 ("Removing webparts from " + $web.Url + "/" + $file.Url)    

    if ($file.InDocumentLibrary -and $file.Item) {
        if ( IsCheckedOut($file) -and !IsCheckedOutByCurrentUser($file)) {
		
			$fileid = [Guid]$file.UniqueId
			Log 1 ("File checked out by other user, overriding checkout")
			if( !$whatIf  ){
				PublishListItem $file.Item $file.Item.ParentList "Override checkout to fix error webparts"
			}
			#re-get file to work on it
			$file = $web.GetFile( $fileid )		
        } 
        else {
            if ( $file.MinorVersion -gt 0 ){
                 #publish a major version to clear old drafts
		  	     Log 1 ("File with minor version, publishing major")
			     if( !$whatIf  ){
				    PublishListItem $file.Item $file.Item.ParentList "Override checkout to fix error webparts"
			     }
			     #re-get file to work on it
			     $file = $web.GetFile( $fileid )		
             }
        }
    }



	#new catch scope 
	&{ 	
        #Checkout the file as we know that we're going to modify the webparts on it (unless we made an error somewhere else)
        $file.CheckOut()

		#Perhaps use both a personal and shared manager, uncertain if it's required
		$managers = ( 	$file.GetLimitedWebPartManager([System.Web.UI.WebControls.WebParts.PersonalizationScope]::Shared) #, 
						#$file.GetLimitedWebPartManager([System.Web.UI.WebControls.WebParts.PersonalizationScope]::User)
						)

		$managerCount = 0
		
		foreach( $manager in $managers ){
	
			$managerCount += 1

			if(!$manager ){
				continue
			}
			
			$fileModified = $false

			$webParts = @($manager.WebParts)
			for ($i = 0; $i -lt $webParts.Count; $i++)
			{
				$webPart = $webParts[$i]

    			#get webpart instance id (format "g_<xxxxxxxx_xxxx_xxxx_xxxx_xxxxxxxxxxxx>")
				$webPartId = [Guid]$webPart.Id.substring(2).replace("_", "-")
				
				if( $errorWebPartIds.ContainsKey( $webPartId ) -or $webPart.FatalError){
					Log 1 ( "Deleting missing webpart at page '" + $web.Url + "/" + $file.Url + "', manager: $managerCount" )
					if( !$whatIf  ){                        
						$manager.DeleteWebPart($webPart)
						$fileModified = $true
					}					
				}					
				else{
					Log 3 ("Considered (and skipped):" + $webPart.Id + ", " + $webPart.Title )
				}
					
				if ($webPart) {
					$webPart.Dispose() 
				}

				trap {
					Log 0 ("CheckAndRemoveMissingWebpartsFromFile: Exception caught (1):" + $_.Exception.ToString()  + ", line: " + $_.Exception.Line)
					break
				}
      			
			}
				
				

			if ($fileModified){
				if( !$whatIf  ){
					$file.CheckIn("Checking in changes; removed error webparts")
				}
			}
				
			if ($file.InDocumentLibrary -and $fileModified) {
				if( !$whatIf  ){
					PublishListItem $file.Item  $file.Item.ParentList  "Removed faulty webparts"
				}
			}
			
            if( !$fileModified ) {
                #Checked out in vain
                $file.UndoCheckOut()
            }
              

			if ($manager){
				$manager.Web.Dispose() # manager.Dispose() does not dispose of the SPWeb object and results in a memory leak.
				$manager.Dispose()
			}					
		}
        
		trap {
			Log 0 ("CheckAndRemoveMissingWebpartsFromFile: (manager count: $managerCount) Exception caught (2):" + $_.Exception.ToString()  + ", line: " + $_.Exception.Line)
			break
		}    
	} 
	
	return
}


# <summary>
# Gets the checked out user id.
# </summary>
# <param name="item">The item.</param>
# <returns></returns>
# 
# Adapted from Gary Lapointe
function GetCheckedOutUserId($file) #SPFile
{
    if ($file)
    {
        if (!$file.CheckedOutBy ){
            return
		}

        return $file.CheckedOutBy.LoginName
    }
    if ($file.Item.ParentList.BaseType -eq [Microsoft.SharePoint.SPBaseType]::DocumentLibrary)
    {
       	return [string]$file.Item["CheckoutUser"]
    }
	return
}
		

# <summary>
# Determines whether [is checked out by current user] [the specified item].
# </summary>
# <param name="item">The item.</param>
# <returns>
# 	<c>true</c> if [is checked out by current user] [the specified item] otherwise, <c>false</c>.
# </returns>
# 
# Adapted from Gary Lapointe
function IsCheckedOutByCurrentUser($file) #SPFile 
{
    $user = GetCheckedOutUserId($file)
    if ([string]::IsNullOrEmpty($user)){
        return $false
	}
    return ((Environment.UserDomainName + "\\" + Environment.UserName).ToLowerInvariant() -eq $user.ToLowerInvariant())
}

# <summary>
# Determines whether the list item is checked out..
# </summary>
# <param name="item">The item.</param>
# <returns>
# 	<c>true</c> if is checked out otherwise, <c>false</c>.
# </returns>
# 
# Adapted from Gary Lapointe
function IsCheckedOut($file) #SPFile
{
	$s = GetCheckedOutUserId($file)
    return !([string]::IsNullOrEmpty( $s ))
}


# <summary>
# Publishes the list item.
# </summary>
# <param name="item">The item.</param>
# <param name="list">The list.</param>
# <param name="settings">The settings.</param>
# <param name="source">The source.</param>
# 
# Adapted from Gary Lapointe
function PublishListItem($item, $list, $source)
{
	trap  {    
        Log 0 ([string]::Format("An error occured checking in an item:\r\n{0}", $_.Exception.ToString()))
		break
    }


	$item = $item.ParentList.GetItemById($item.ID)
    if ($item.File)
    {
        # We first need to handle the case in which we have a file which means that
        # we have to deal with the possibility that the file may be checked out.
        if ($item.Level -eq [Microsoft.SharePoint.SPFileLevel]::Checkout)
        {
            # The file is checked out so we now need to check it in - we'll do a major
            # checkin which will result in it being published.

			$item.File.CheckIn("Checked in by " + $source, [Microsoft.SharePoint.SPCheckinType]::MajorCheckIn)
            # We need to get the File's version of the SPListItem so that we get the changes.
            # Calling item.Update() will fail because the file is no longer checked out.
            # If workflow is supported this should now be in a pending state.
            # Re-retrieve the item to avoid save conflict errors.
            $item = $item.ParentList.GetItemById($item.ID)

            Log 2 ( "Checked in item: " + $item.Title + " (" + $item.Url + ")" )
        }
        elseif ($item.Level -eq  [Microsoft.SharePoint.SPFileLevel]::Draft -and !$item.ModerationInformation)
        {
            # The file isn't checked out but it is in a draft state so we need to publish it.

			$item.File.Publish("Published by " + $source)
            # We need to get the File's version of the SPListItem so that we get the changes.
            # Calling item.Update() will fail because the file is no longer checked out.
            # If workflow is supported this should now be in a pending state.
            # Re-retrieve the item to avoid save conflict errors.
            $item = $item.ParentList.GetItemById($item.ID)

            Log 2 ( [string]::Format("Published item: {0} ({1})", $item.Title, $item.Url))
        }
    }

    if ($item.ModerationInformation)
    {
        # If ModerationInformation is not null then the item supports content approval.
        if (!$item.File -and ($item.ModerationInformation.Status -eq [Microsoft.SharePoint.SPModerationStatusType]::Draft -or
            $item.ModerationInformation.Status -eq [Microsoft.SharePoint.SPModerationStatusType]::Pending))
        {
            # If content approval is supported but no file is associated with the item then we have
            # to treat it differently.  We simply set the status information directly.

			&{
				# Because the SPListItem object has no direct approval method we have to 
				# set the information directly (there's no SPFile object to use).
				CancelWorkflows $list $item
				$item.ModerationInformation.Status = [Microsoft.SharePoint.SPModerationStatusType]::Approved
				$item.ModerationInformation.Comment = "Approved by " + $source
				$item.Update() # Because there's no SPFile object we don't have to worry about the item being checkedout for this to succeed as you can't check it out.
				# Re-retrieve the item to avoid save conflict errors.
				$item = $item.ParentList.GetItemById($item.ID)

				Log 2 ([string]::Format("Approved item: {0} ({1})", $item.Title, $item.Url))
				
				trap 
				{
					Log 0 ( [string]::Format("An error occured approving an item:\r\n{0}", $_.Exception.ToString() ))
					break
				}
			}
        }
        else
        {
            # The item supports content approval and we have an SPFile object to work with.
            &{
                if ($item.ModerationInformation.Status -eq [Microsoft.SharePoint.SPModerationStatusType]::Pending)
                {
                    # The item is pending so it's already been published - we just need to approve.
                    # Cancel any workflows.
                    CancelWorkflows $list $item
                    $item.File.Approve("Approved by " + $source)
                    # Re-retrieve the item to avoid save conflict errors.
                    $item = $item.ParentList.GetItemById($item.ID)
                                        
                    Log 2 ([string]::Format("Approved item: {0} ({1})", $item.Title, $item.Url))
                }
            
				trap
				{
					Log 0 ([string]::Format("An error occured approving an item:\r\n{0}", $_.Exception.ToString() ))
					
				}
			}

            
            &{
                if ($item.ModerationInformation.Status -eq [Microsoft.SharePoint.SPModerationStatusType]::Draft)
                {
                    # The item is in a draft state so we have to first publish it and then approve it.
                    if (IsCheckedOut($item.File))
                    {
                        $item.File.CheckIn("Checked in by " + $source, [Microsoft.SharePoint.SPCheckinType]::MajorCheckIn)
                        Log  ([string]::Format("Checked in item: {0} ({1})", $item.Title, $item.Url))
                    }
                    $item.File.Publish("Published by " + $source)
                    # Cancel any workflows.
                    CancelWorkflows $list $item
                    $item.File.Approve("Approved by " + $source)
                    # We don't need to re-retrieve the item as we're now done with it.

					Log 2 ( [string]::Format("Published item: {0} ({1})", $item.Title, $item.Url))
                }
				Trap 
				{
					Log 0 ([string]::Format("An error occured approving an item:\r\n{0}", $_.Exception.ToString() ))
				}
			}
        }
    }
}

# <summary>
# Cancels the workflows.  This code is a re-engineering of the code that Microsoft uses
# when approving an item via the browser.  That code is in Microsoft.SharePoint.ApplicationPages.ApprovePage.
# </summary>
# <param name="settings">The settings.</param>
# <param name="list">The list.</param>
# <param name="item">The item.</param>
# 
# Adapted from Gary Lapointe
function CancelWorkflows($list, $item){
    if ($list.DefaultContentApprovalWorkflowId -ne [Guid]::Empty -and
        $item.DoesUserHavePermissions(([Microsoft.SharePoint.SPBasePermissions]::ApproveItems +
                                      [Microsoft.SharePoint.SPBasePermissions]::EditListItems)))
    {
        # If the user has rights to do so then we need to cancel any workflows that
        # are associated with the item.
        [Microsoft.SharePoint.SPSecurity]::RunWithElevatedPrivileges(
            
                {
                    foreach ($workflow in $item.Workflows)
                    {
                        if ($workflow.ParentAssociation.Id -ne
                            $list.DefaultContentApprovalWorkflowId)
                        {
                            continue;
                        }
                        [Microsoft.SharePoint.SPWorkflowManager]::CancelWorkflow($workflow);
                        Log 1 ([string]::Format("Cancelling workflow {0} for item: {1} ({2})",
                                          $workflow.WebId, $item.Title, $item.Url));
                    }
                });
    }
        
}

# Generic logging method
function Log( $level, $message ){
    #3 very verbose
    #2 Info
    #1 warning (yellow)
    #0 Error (red)

	$time = [DateTime]::Now.ToString("s") + " "
	

	if( $whatIf ){
		$whatIfMsg = " (WhatIf) "
	}
   
	
    if( $level -le $verboselevel){
        if ($level -eq 0 ){
            Write-host -ForegroundColor Red ("$time Error: $whatIfMsg" +  $message)			
            Write ("$time Error: $whatIfMsg" +  $message)			
        }    
        elseif ($level -eq 1 ){ 
            Write-host -ForegroundColor Yellow ("$time Warning: $whatIfMsg" + $message)
            Write ("$time Warning: $whatIfMsg" + $message)
        }
        else{
            Write ($time + " " + $whatIfMsg + $message)
        }   
    }
}


#Execute!
FixUpdateIssues 

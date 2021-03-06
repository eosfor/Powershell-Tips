Function Test-Site {
    #Based on http://learn-powershell.net/2012/05/13/using-background-runspaces-instead-of-psjobs-for-better-performance/
    [cmdletbinding()]
    Param (
        [parameter()]
        [string]$URI = "http://oper.ru",       
        [parameter()]
        [int]$Throttle = 32
    )
    Begin {
        #suppress progress
        $progressOld = $ProgressPreference
        $ProgressPreference=’SilentlyContinue'

        #Function that will be used to process runspace jobs
        Function Get-RunspaceData {
            [cmdletbinding()]
            param(
                [switch]$Wait
            )
            Do {
                $more = $false         
                Foreach($runspace in $runspaces) {
                    If ($runspace.Runspace.isCompleted) {
                        $runspace.powershell.EndInvoke($runspace.Runspace)
                        $runspace.powershell.dispose()
                        $runspace.Runspace = $null
                        $runspace.powershell = $null
                        $Script:i++                  
                    } ElseIf ($runspace.Runspace -ne $null) {
                        $more = $true
                    }
                }
                If ($more -AND $PSBoundParameters['Wait']) {
                    Start-Sleep -Milliseconds 100
                }   
                #Clean out unused runspace jobs
                $temphash = $runspaces.clone()
                $temphash | Where {
                    $_.runspace -eq $Null
                } | ForEach {
                    Write-Verbose ("Removing {0}" -f $_.computer)
                    $Runspaces.remove($_)
                }             
            } while ($more -AND $PSBoundParameters['Wait'])
        }
               
        #Main collection to hold all data returned from runspace jobs
        $Script:report = @()    
                
        #Define hash table for Get-RunspaceData function
        $runspacehash = @{}

        #Define Scriptblock for runspaces
        $ScriptBlock = {
            Param ($lnk)
             $progressOld = $ProgressPreference
             $ProgressPreference=’SilentlyContinue’
             $obj = new-object psobject -prop @{Name = $lnk; Status = (Invoke-WebRequest -Uri $lnk -DisableKeep).statuscode}
             $ProgressPreference = $progressOld
             $obj
        }
        
        Write-Verbose ("Creating runspace pool and session states")
        $sessionstate = [system.management.automation.runspaces.initialsessionstate]::CreateDefault()
        $runspacepool = [runspacefactory]::CreateRunspacePool(1, $Throttle, $sessionstate, $Host)
        $runspacepool.Open()  
        
        Write-Verbose ("Creating empty collection to hold runspace jobs")
        $Script:runspaces = New-Object System.Collections.ArrayList        
    }
    Process {
        
        $links = (Invoke-WebRequest -Uri $URI).links.href
        $totalcount = $links.count
        $linksHash = @{}

        #create a hashtable of links to check
        foreach ($link in $links){
            if ($link -match "^http"){
                if (! $linksHash[$link] ){
                   #add link to the hash to avoid double checking
                   write-verbose "Checking $link"
                   $linksHash[$link] = $link                
                }
                else{
                    write-verbose "Skipping $link`: existing"
                }
            }
            else{
                write-verbose "Skipping $link`: not HTTP"
            }
        }

        ForEach ($link in $linksHash.Values) {              
            #Create the powershell instance and supply the scriptblock with the other parameters 
            $powershell = [powershell]::Create().AddScript($ScriptBlock).AddArgument($link)
           
            #Add the runspace into the powershell instance
            $powershell.RunspacePool = $runspacepool
           
            #Create a temporary collection for each runspace
            $temp = "" | Select-Object PowerShell,Runspace,Link
            $Temp.Link = $link
            $temp.PowerShell = $powershell
           
            #Save the handle output when calling BeginInvoke() that will be used later to end the runspace
            $temp.Runspace = $powershell.BeginInvoke()
            Write-Verbose ("Adding {0} collection" -f $temp.Computer)
            $runspaces.Add($temp) | Out-Null
           
            Write-Verbose ("Checking status of runspace jobs")
            Get-RunspaceData @runspacehash
       }
    }
    End {                     
        Write-Verbose ("Finish processing the remaining runspace jobs: {0}" -f (@(($runspaces | Where {$_.Runspace -ne $Null}).Count)))
        $runspacehash.Wait = $true
        Get-RunspaceData @runspacehash
        
        Write-Verbose ("Closing the runspace pool")
        $runspacepool.close()

        #restore progress
        $ProgressPreference = $progressOld
    }
}



test-site -Verbose
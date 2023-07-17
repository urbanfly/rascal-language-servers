/*
 * Copyright (c) 2018-2023, NWO-I CWI and Swat.engineering
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice,
 * this list of conditions and the following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above copyright notice,
 * this list of conditions and the following disclaimer in the documentation
 * and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
 * LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 */
import {CancellationToken, DebugConfiguration, DebugConfigurationProvider, ProviderResult, WorkspaceFolder, window} from "vscode";
import { RascalDebugClient } from "./RascalDebugClient";

/**
 * Class used by Vscode when starting debug sessions to add configuration information before it launchs
 */
export class RascalDebugConfigurationProvider implements DebugConfigurationProvider {

    debugClient: RascalDebugClient;

    constructor(debugClient: RascalDebugClient){
        this.debugClient = debugClient;
    }

    provideDebugConfigurations(folder: WorkspaceFolder | undefined, token?: CancellationToken | undefined): ProviderResult<DebugConfiguration[]> {
        const conf: DebugConfiguration = {type: "rascalmpl", name: "Rascal Debug", request: "attach"};
        return [conf];
    }

    async resolveDebugConfiguration(folder: WorkspaceFolder | undefined, debugConfiguration: DebugConfiguration, token?: CancellationToken | undefined): Promise<DebugConfiguration> {
        return new Promise((resolve, reject) => {
            if(token !== undefined){
                token.onCancellationRequested((e) => {
                    reject(e);
                });
            }

            if (debugConfiguration.type === undefined) {
                debugConfiguration.type = "rascalmpl";
                debugConfiguration.name = "Rascal Debug";
                debugConfiguration.request = "attach";
            }

            if (!debugConfiguration.serverPort){
                window.activeTerminal?.processId.then((value: number|undefined) => {
                    const port = this.debugClient.getServerPort(value);
                    if(port === undefined) {
                        reject("Active terminal has not a debug server port registered !");
                    } else {
                        if(this.debugClient.isConnectedToDebugServer(port)){
                            reject("This REPL has already a running debug session !");
                        } else {
                            debugConfiguration.serverPort = port;
                            resolve(debugConfiguration);
                        }
                    }
                }, (reason: any) => {
                    reject(reason);
                });
            } else {
                resolve(debugConfiguration);
            }
        });
    }

}
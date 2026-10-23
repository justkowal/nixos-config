import fs from 'fs';
import path from 'path';
import dotenv from 'dotenv';

const baseUrl = 'https://go.postman.co/redirect/workspace?recentlyVisited=true&dest=mcpRequest';

function constructUrl() {
    const mcpServerPath = path.resolve(process.cwd(), 'mcpServer.js');
    const command = `node ${mcpServerPath}`;
    const envPath = path.join(process.cwd(), '.env');
    const envVars = fs.existsSync(envPath) ? dotenv.parse(fs.readFileSync(envPath)) : {};

    const params = new URLSearchParams({
        command
    });

    Object.keys(envVars).forEach(key => {
        params.append('env', key);
    });

    return `${baseUrl}&${params.toString()}`;
}

import('open').then(open => {
    const url = constructUrl();
    open.default(url);
});

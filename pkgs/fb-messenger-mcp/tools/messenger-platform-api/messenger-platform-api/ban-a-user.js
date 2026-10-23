import { getToken, getPageId } from "../../../lib/fb.js";

/**
 * Function to ban a user from a Facebook page using the Messenger Platform API.
 *
 * @param {Object} args - Arguments for the ban action.
 * @param {string} args.pageScopedId - The page-scoped ID of the user to be banned.
 * @param {string} args.pageId - The ID of the Facebook page.
 * @param {string} args.version - The API version to use.
 * @returns {Promise<Object>} - The result of the ban action.
 */
const executeFunction = async (args = {}) => {
  const { pageScopedId, pageId, version } = args;
  const token = getToken();
  const url = `https://graph.facebook.com/${version}/${getPageId(typeof pageId !== "undefined" ? pageId : args.pageId)}/moderate_conversations`;
  
  const body = JSON.stringify({
    user_ids: [{ id: pageScopedId }],
    actions: ["ban_user"]
  });

  try {
    // Set up headers for the request
    const headers = {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${token}`
    };

    // Perform the fetch request
    const response = await fetch(url, {
      method: 'POST',
      headers,
      body
    });

    // Check if the response was successful
    if (!response.ok) {
      const errorData = await response.json();
      throw new Error(JSON.stringify(errorData));
    }

    // Parse and return the response data
    const data = await response.json();
    return data;
  } catch (error) {
    console.error('Error banning user:', error);
    return {
      error: `An error occurred while banning the user: ${error instanceof Error ? error.message : JSON.stringify(error)}`
    };
  }
};

/**
 * Tool configuration for banning a user from a Facebook page.
 * @type {Object}
 */
const apiTool = {
  function: executeFunction,
  definition: {
    type: 'function',
    function: {
      name: 'ban_user',
      description: 'Ban a user from a Facebook page.',
      parameters: {
        type: 'object',
        properties: {
          pageScopedId: {
            type: 'string',
            description: 'The page-scoped ID of the user to be banned.'
          },
          pageId: {
            type: 'string',
            description: 'The ID of the Facebook page.'
          },
          version: {
            type: 'string',
            description: 'The API version to use.'
          }
        },
        required: ['pageScopedId', 'pageId', 'version']
      }
    }
  }
};

export { apiTool };
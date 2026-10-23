import { getToken, getPageId } from "../../../lib/fb.js";

/**
 * Function to send a button template message via the Messenger Platform API.
 *
 * @param {Object} args - Arguments for sending the message.
 * @param {string} args.pageId - The ID of the Facebook page to send the message to.
 * @param {string} args.recipientId - The recipient's ID to whom the message will be sent.
 * @param {string} [args.version='v22.0'] - The version of the Messenger API to use.
 * @returns {Promise<Object>} - The result of the message sending operation.
 */
const executeFunction = async (args = {}) => {
  const { pageId, recipientId, version = 'v22.0' } = args;
  const baseUrl = 'https://graph.facebook.com';
  const token = getToken();
  try {
    // Construct the URL for the API request
    const url = `${baseUrl}/${version}/${getPageId(typeof pageId !== "undefined" ? pageId : args.pageId)}/messages`;

    // Create the message payload
    const payload = {
      recipient: {
        id: recipientId
      },
      message: {
        attachment: {
          type: 'template',
          payload: {
            template_type: 'button',
            text: 'What do you want to do next?',
            buttons: [
              {
                type: 'web_url',
                url: 'https://www.messenger.com',
                title: 'Visit Messenger'
              }
            ]
          }
        }
      }
    };

    // Set up headers for the request
    const headers = {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${token}`
    };

    // Perform the fetch request
    const response = await fetch(url, {
      method: 'POST',
      headers,
      body: JSON.stringify(payload)
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
    console.error('Error sending button template message:', error);
    return {
      error: `An error occurred while sending the message: ${error instanceof Error ? error.message : JSON.stringify(error)}`
    };
  }
};

/**
 * Tool configuration for sending button template messages via the Messenger Platform API.
 * @type {Object}
 */
const apiTool = {
  function: executeFunction,
  definition: {
    type: 'function',
    function: {
      name: 'send_button_template_message',
      description: 'Send a button template message via the Messenger Platform API.',
      parameters: {
        type: 'object',
        properties: {
          pageId: {
            type: 'string',
            description: 'The ID of the Facebook page to send the message to.'
          },
          recipientId: {
            type: 'string',
            description: 'The recipient\'s ID to whom the message will be sent.'
          },
          version: {
            type: 'string',
            description: 'The version of the Messenger API to use.'
          }
        },
        required: ['pageId', 'recipientId']
      }
    }
  }
};

export { apiTool };
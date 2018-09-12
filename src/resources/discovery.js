class Discovery {
  constructor({ discoveryServerUrl, fetch }) {
    this.discoveryServerUrl = discoveryServerUrl
    this.fetch = fetch
  }

  async query(graphQlQuery){
    const url = this.discoveryServerUrl
    const resp = await this.fetch(url, {
      method: 'POST',
      body: JSON.stringify({
        query: graphQlQuery
      }),
      headers: {
        'Content-Type': 'application/json'
      }
    })
    if(resp.status != 200){
      throw Error('Got non-sucess code from GraphQL server')
    }
    return await resp.json()
  }

  /**
   * Issues a search request to the indexing server which returns Listings result as a promise.
   * This way the caller of the function can implement error checks when results is something
   * unexpected. To get JSON result caller should call `await searchResponse.json()` to get the
   * actual JSON.
   * @param searchQuery {string} general search query
   * @param listingType {string} one of the supported listingTypes
   * @param filters {object} object with properties: name, value, valueType, operator
   * @returns {Promise<HTTP_Response>}
   */
  async search(searchQuery, listingType, filters = []) {
    const query = `
    {
      listings (
        searchQuery: "${searchQuery}"
        filters: [${filters
    .map(filter => {
      return `
    {
      name: "${filter.name}"
      value: "${String(filter.value)}"
      valueType: ${filter.valueType}
      operator: ${filter.operator}
    }
    `
    })
    .join(',')}]
      ) {
        nodes {
          id
        }
      }
    }`

    return this.query(query)
  }
}

module.exports = Discovery